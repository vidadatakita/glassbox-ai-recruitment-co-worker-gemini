# frozen_string_literal: true

module Briefs
  # Saves one step of the "Buat Lowongan" wizard (blueprint §3.1 screen 2) and records the change
  # (D49 (5)). One transaction: the step's fields, its rows, the stage rows of a complete brief,
  # and the audit row land together or not at all.
  #
  # A DRAFT may be saved half-filled (cross-row rules such as "shares sum to 100" are judged by
  # Briefs::BriefCheck when the brief is completed). Two things are refused at every save:
  #   - a malformed row or number (a row with a description but no output, "abc" as a share);
  #   - a change to a field frozen by rule 3 once any stage has opened (Job#brief_locked?), and a
  #     change to the knockout questions once any application exists, because the Lamar answers
  #     are keyed by question id (lamar_controller #knockout_params).
  # A COMPLETE brief stays complete: a save that would break BriefCheck is refused whole.
  class SaveStep
    Result = Data.define(:ok, :job, :errors) do
      def ok? = ok
    end
    Refused = Class.new(StandardError) do
      attr_reader :errors

      def initialize(errors)
        @errors = Array(errors)
        super(@errors.join(" "))
      end
    end
    STEPS = %w[1 2 3 4].freeze
    LOCKED = "A selection stage has opened, so this section is locked (locking rule, blueprint §2.2 rule 3)."

    def self.call(job:, step:, params:, actor:) = new(job:, step:, params:, actor:).call

    def initialize(job:, step:, params:, actor:)
      raise ArgumentError, "unknown step #{step.inspect}" unless STEPS.include?(step.to_s)

      @job = job
      @step = step.to_s
      @params = Params.new(params.to_h.deep_stringify_keys)
      @actor = actor
    end

    def call
      before = @job.new_record? ? {} : Snapshot.take(@job, @step)
      ActiveRecord::Base.transaction do
        apply_step
        @pending_rows&.call
        raise Refused, @row_errors if @row_errors&.any?

        record_change(before)
      end
      Result.new(true, @job, [])
    rescue Refused => e
      Result.new(false, @job, e.errors)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(false, @job, e.record.errors.full_messages)
    end

    private

    def locked? = @locked ||= (@job.persisted? && @job.brief_locked?)

    def knockout_locked? = locked? || (@job.persisted? && @job.job_applications.exists?)

    def apply_step
      errors = send("apply_step_#{@step}")
      raise Refused, errors if errors.any?

      @job.save!
    end

    # --- step 1: Posisi & level -------------------------------------------------------------
    def apply_step_1
      errors = []
      golongan = @params.integer("golongan", errors, "Grade")
      if locked? && golongan != @job.golongan
        errors << "The grade cannot be changed. #{LOCKED}"
      else
        @job.golongan = golongan
      end
      errors << "Grade is required." if @job.golongan.nil?
      # F-05: out-of-range values get a screen message here instead of reaching the model, whose
      # message would carry an English attribute name.
      if @job.golongan && !(1..8).cover?(@job.golongan)
        errors << "Grade must be one of G1 to G8."
        @job.golongan = @job.golongan_was
      end
      @job.title = @params.text("title")
      errors << "Position is required." if @job.title.blank?
      @job.headcount = @params.integer("headcount", errors, "Headcount")
      errors << "Headcount must be at least 1 person." if @job.headcount&.zero?
      @job.employment_type = @params.choice("employment_type", Job::EMPLOYMENT_TYPES)
      @job.confidential = @params.boolean("confidential")
      errors
    end

    # --- step 2: Aktivitas & target 90 hari --------------------------------------------------
    def apply_step_2
      @job.success_90d = @params.text("success_90d")
      @pending_rows = -> { save_rows(@job.activities, stable_activity_rows, "Activity") { |row, errs, label| activity_attrs(row, errs, label) } }
      []
    end

    # Activity ids survive a step-2 save whose rows carry no ids (a raw POST, a stale tab), the same
    # way knockout questions do (F-03 above). The technical test's rubric links each criterion to an
    # activity id (feature 07); re-creating the rows gave them new ids and left an APPROVED rubric
    # pointing at nothing (test engine 07 F-05, 2026-10-10). An id-less row takes the unclaimed saved
    # activity with the same description first, then the next unclaimed one in position order; only
    # rows beyond the saved ones are new.
    def stable_activity_rows
      rows = @params.rows("activities").map(&:dup)
      saved = @job.persisted? ? @job.activities.to_a : []
      claimed = rows.filter_map { |row| row["id"].presence&.to_s }
      free = saved.reject { |a| claimed.include?(a.id.to_s) }
      rows.select { |row| filled?(row) && row["id"].blank? }.each do |row|
        key = row["description"].to_s.strip.downcase
        match = free.find { |a| a.description.to_s.strip.downcase == key } || free.first
        next unless match

        row["id"] = match.id.to_s
        free.delete(match)
      end
      rows
    end

    def activity_attrs(row, errors, label)
      errors << "#{label}: the activity description is required." if row["description"].to_s.strip.empty?
      errors << "#{label}: the output is required." if row["output"].to_s.strip.empty?
      share = @params.integer_value(row["share_percent"], errors, "#{label}: time share")
      errors << "#{label}: the time share is required (0 to 100)." if share.nil? || share > 100
      { description: row["description"].to_s.strip, output: row["output"].to_s.strip, share_percent: share }
    end

    # --- step 3: Syarat & kompensasi ---------------------------------------------------------
    def apply_step_3
      errors = []
      @job.salary_min = @params.rupiah("salary_min", errors, "Minimum salary")
      @job.salary_max = @params.rupiah("salary_max", errors, "Maximum salary")
      errors << "Minimum salary must be more than Rp0." if @job.salary_min&.zero?
      errors << "Maximum salary must be more than Rp0." if @job.salary_max&.zero?
      if @job.salary_min && @job.salary_max && @job.salary_min > @job.salary_max
        errors << "Minimum salary is higher than the maximum salary; swap the two figures."
      end
      @job.show_salary = @params.boolean("show_salary")
      @job.placements = @params.list("placements")
      # Candidate pages (candidate_shared/_job_top) read the single `location` line, which predates
      # placements. It is DERIVED here so the city is asked once (layout contract §5.0 point 6).
      @job.location = @job.placements.join(", ").presence
      @job.relocation = @params.choice("relocation", Job::RELOCATIONS)
      @job.work_arrangement = @params.choice("work_arrangement", Job::WORK_ARRANGEMENTS)
      if @params.key?("requirements")
        if locked?
          errors << "Requirements and knockout questions cannot be changed. #{LOCKED}"
        else
          @pending_rows = -> { save_requirements }
        end
      end
      errors
    end

    # --- step 4: Paket & tahapan -------------------------------------------------------------
    def apply_step_4
      return ["Package, stages and competencies cannot be changed. #{LOCKED}"] if locked?

      errors = []
      package = @params.integer("package", errors, "Package")
      errors << "Package must be 1 to 5." if package && !(1..5).cover?(package)
      @job.package = package
      @job.package_override_reason = @params.text("package_override_reason")
      @job.stage_plan = stage_plan(errors) if package && (1..5).cover?(package)
      @pending_rows = -> { save_rows(@job.competencies, @params.rows("competencies"), "Competency") { |row, errs, label| competency_attrs(row, errs, label) } }
      errors
    end

    def stage_plan(errors)
      given = @params.section("stage_plan")
      StagePlan.scored_codes(@job.package).to_h do |code|
        label = StagePlan::LABELS[code]
        weight = @params.integer_value(given.dig(code, "weight"), errors, "Weight of #{label}")
        errors << "Weight of #{label} must be 0 to 100." if weight && weight > 100
        threshold = @params.decimal_value(given.dig(code, "threshold"), errors, "Pass score of #{label}")
        errors << "Pass score of #{label} must be 0 to 100." if threshold && !Totals.threshold?(threshold)
        [code, { "weight" => weight, "threshold" => threshold }]
      end
    end

    def competency_attrs(row, errors, label)
      name = row["name"].to_s.strip
      errors << "#{label}: the competency name is required." if name.empty?
      layer = Competency::LAYERS.key?(row["layer"]) ? row["layer"] : nil
      errors << "#{label}: the layer is required." if layer.nil?
      stage = Competency::STAGE_CODES.include?(row["stage_code"]) ? row["stage_code"] : nil
      errors << "#{label}: the assessing stage is required." if stage.nil?
      { name:, layer:, stage_code: stage, anchor_1: blank_nil(row["anchor_1"]), anchor_3: blank_nil(row["anchor_3"]),
        anchor_5: blank_nil(row["anchor_5"]), questions: blank_nil(row["questions"]) }
    end

    # --- rows --------------------------------------------------------------------------------

    # Upserts the slots of a repeating section. A slot with every visible field blank is skipped,
    # or removed when it held a saved row. Rows are matched by id WITHIN this job, so a forged id
    # from another job raises RecordNotFound instead of editing someone else's brief.
    def save_rows(collection, rows, noun)
      errors = []
      kept = []
      rows.each_with_index.select { |row, _| filled?(row) }.each_with_index do |(row, slot), position|
        label = "#{noun} #{slot + 1}"
        attrs = yield(row, errors, label)
        record = row["id"].present? ? collection.find(row["id"]) : collection.build
        record.assign_attributes(attrs.merge(position: position + 1))
        kept << record
      end
      return @row_errors = errors if errors.any?

      collection.where.not(id: kept.filter_map(&:id)).destroy_all
      kept.each(&:save!)
      kept
    end

    # Knockout questions keep their ids across a save whatever happens to the requirement rows
    # (Lamar answers are keyed by question id). Test engine F-03: a save whose rows carried no ids
    # used to delete every requirement, and with it every question, and re-create both with new
    # ids, while the freeze compared texts only and let it through. Now a removed requirement only
    # unlinks its question (Requirement has_one ... dependent: :nullify) and sync_knockouts links
    # the questions back by requirement, then by text, before it creates or deletes anything.
    def save_requirements
      rows = @params.rows("requirements")
      filled = rows.select { |r| filled?(r) }
      form_questions = @job.knockout_questions.where.not(requirement_id: nil).to_a
      wanted = filled.filter_map { |r| r["knockout"].to_s.strip.presence if r["tier"] == "wajib" }
      if knockout_locked? && wanted.sort != form_questions.map(&:text).sort
        raise Refused, "Knockout questions cannot be changed once applications are in; the applicants' answers are bound to these questions."
      end

      saved = save_rows(@job.requirements, rows, "Requirement") { |row, errs, label| requirement_attrs(row, errs, label) }
      sync_knockouts(saved, filled, form_questions) unless @row_errors&.any?
    end

    def requirement_attrs(row, errors, label)
      tier = Requirement::TIERS.key?(row["tier"]) ? row["tier"] : nil
      errors << "#{label}: unknown requirement tier." if tier.nil?
      errors << "#{label}: the requirement text is required." if row["text"].to_s.strip.empty?
      errors << "#{label}: the CV evidence is required." if row["cv_evidence"].to_s.strip.empty?
      weight = tier == "sebaiknya" ? @params.integer_value(row["weight"], errors, "#{label}: weight") : nil
      errors << "#{label}: the weight must be 0 to 100." if weight && weight > 100
      if row["knockout"].present? && tier != "wajib"
        errors << "#{label}: a knockout question is only for a must-have requirement (rule 16)."
      end
      { tier:, text: row["text"].to_s.strip, cv_evidence: row["cv_evidence"].to_s.strip, weight: }
    end

    # Each "wajib" requirement with a question owns one KnockoutQuestion. Matching, in order: a
    # question with the same text (a moved or re-posted line keeps the id, and the text a
    # candidate answered stays with that id), then the question this requirement already had (a
    # wording edit before any application keeps the id), then a new question. Only questions
    # nobody claimed are deleted, and that is reachable only before any application exists
    # (save_requirements refuses a changed text set after that).
    #
    # Two passes, because (job_id, position) and requirement_id are both unique: renumbering or
    # relinking in place collides with a sibling still holding the old value (test engine F-04,
    # PG::UniqueViolation when a question was typed into the middle wajib line). Pass 1 parks every
    # form question on a negative position with no requirement; pass 2 writes the final values.
    def sync_knockouts(saved, rows, form_questions)
      wanted = saved.zip(rows).filter_map { |req, row| [req, row["knockout"].to_s.strip] if req.tier == "wajib" && row["knockout"].present? }
      previous = form_questions.to_h { |q| [q.id, q.requirement_id] }
      KnockoutQuestion.where(id: previous.keys).update_all("requirement_id = NULL, position = -id")
      pool = form_questions.dup
      claim = ->(&test) { (q = pool.find(&test)) && pool.delete(q) }
      chosen = wanted.map { |_, text| claim.call { |q| q.text == text } }
      wanted.each_with_index { |(req, _), i| chosen[i] ||= claim.call { |q| previous[q.id] == req.id } }
      KnockoutQuestion.where(id: pool.map(&:id)).destroy_all
      base = @job.knockout_questions.where(requirement_id: nil).where("position > 0").maximum(:position).to_i
      wanted.each_with_index do |(req, text), i|
        question = chosen[i] ? KnockoutQuestion.find(chosen[i].id) : @job.knockout_questions.build
        question.update!(requirement: req, text:, position: base + i + 1)
      end
    end

    # --- audit + completeness ----------------------------------------------------------------

    def record_change(before)
      @job.reload
      keep_complete!
      changes = Snapshot.diff(before, Snapshot.take(@job, @step))
      return if changes.empty?

      JobBriefChange.create!(job: @job, actor: @actor, actor_role: @actor.role, step: @step, changes_made: changes,
                             created_at: Time.current)
    end

    def keep_complete!
      return unless @job.brief_complete?

      problems = BriefCheck.new(@job).problems
      if problems.any?
        # Each line names its step: the problems are usually in OTHER steps than the one being saved
        # (17 Oct 2026, a step-3 save on a seeded "complete" brief listed step-2 and step-4 gaps with
        # no step named, and read as a broken Save button).
        raise Refused, ["This brief is complete, so every change must keep it complete. Fix these first:",
                        *problems.map { |p| "Step #{p.step} (#{JobBriefChange::STEP_LABELS.fetch(p.step.to_s, 'brief')}): #{p.message}" }]
      end

      # A locked brief cannot change its stage plan (step 4 is refused above), and its opened
      # stages must not be rewritten, so only an unlocked complete brief re-syncs.
      SyncStages.call(@job) unless locked?
    end

    def filled?(row) = row.except("id", "tier").values.any? { |v| v.to_s.strip.present? }

    def blank_nil(value) = value.to_s.strip.presence
  end
end
