module TestCases
  # Brief step 5 "Technical test" (D60, plan §c): the job's consultant uploads the case file and writes
  # the instructions, time limit, allowed answer types and rubric. Two cases:
  #   - the newest version is still a DRAFT nobody started: it is edited in place;
  #   - otherwise (no version yet, or the newest is approved or started): version n + 1 is created,
  #     and from version 2 on it needs a reason (plan §c "a new version with a reason").
  # A draft may be saved half-filled (like the brief steps); malformed values are refused at every
  # save, never read as 0. Completeness (weights 100, a file, an answer type) is checked at approval.
  # One transaction: the version, its rubric rows, the file and the audit row, or nothing.
  class SaveVersion
    Result = Data.define(:ok, :errors, :test_case) do
      def ok? = ok
    end
    Refused = Class.new(StandardError)
    CRITERIA_SLOTS = 6

    def self.call(**kwargs) = new(**kwargs).call

    # params: instructions, time_limit_minutes, answer_types[], new_version_reason, case_file (upload),
    #         criteria: { "0" => { activity_id, name, weight, anchor_1, anchor_3, anchor_5 }, ... }
    def initialize(job:, actor:, params:, now: Time.current)
      @job = job
      @actor = actor
      @raw = params.to_h.with_indifferent_access
      @params = Briefs::Params.new(@raw)
      @now = now
      @errors = []
    end

    def call
      authorize!
      ActiveRecord::Base.transaction do
        @job.lock!
        @test_case = target
        before = TestCases::Snapshot.of(@test_case)
        assign_fields
        attach_file
        raise Refused if @errors.any?

        @test_case.save!
        write_criteria
        raise Refused if @errors.any?

        audit(before)
      end
      Result.new(true, [], @test_case)
    rescue Refused
      Result.new(false, @errors, @test_case)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(false, @errors + e.record.errors.full_messages, @test_case)
    end

    private

    def authorize!
      return if Authority.may_edit?(@actor, @job)

      @errors << Authority.edit_refusal(@actor, @job)
      raise Refused
    end

    def target
      latest = TechnicalTestCase.latest_for(@job)
      return latest if latest&.editable?

      reason = @params.text(:new_version_reason)
      if latest && reason.nil?
        @errors << "The reason for the new version is required, because version #{latest.version} is already #{latest.approved? ? 'approved' : 'in use by applicants'}."
      end
      TechnicalTestCase.new(job: @job, version: (latest&.version || 0) + 1, created_by: @actor, new_version_reason: reason,
                   time_limit_minutes: latest&.time_limit_minutes || TechnicalTestCase::DEFAULT_TIME_LIMIT).tap do |fresh|
        copy_from(latest, fresh) if latest
      end
    end

    # A new version starts as a copy of the newest one, so "change one thing" means one thing.
    def copy_from(latest, fresh)
      fresh.assign_attributes(latest.slice(:instructions, :answer_types, :case_file_blob_id, :case_file_kind,
                                           :case_file_sha256, :case_file_bytes, :scan_state, :scanned_at))
      @copied_blob = latest.case_file.blob if latest.case_file.attached?
      @copied_criteria = latest.criteria.map { |c| c.slice(:activity_id, :activity_text, :name, :weight, :anchor_1, :anchor_3, :anchor_5) }
    end

    def assign_fields
      @test_case.instructions = @params.text(:instructions).to_s if @params.key?(:instructions)
      if @params.key?(:time_limit_minutes)
        minutes = @params.integer(:time_limit_minutes, @errors, "Time limit")
        if minutes && !(1..TechnicalTestCase::MAX_TIME_LIMIT).cover?(minutes)
          @errors << "Time limit #{minutes} minutes is out of range; enter 1 to #{TechnicalTestCase::MAX_TIME_LIMIT} minutes."
        elsif minutes
          @test_case.time_limit_minutes = minutes
        end
      end
      @test_case.answer_types = @params.list(:answer_types) & TechnicalTestCase::ANSWER_TYPES.keys if @params.key?(:answer_types_submitted)
    end

    def attach_file
      upload = @raw[:case_file]
      if upload.respond_to?(:read)
        inspection = FileInspection.call(io: upload, filename: upload.original_filename)
        return @errors.concat(inspection.problems.map { |m| "Case study file: #{m}" }) unless inspection.ok?

        record_file(upload, inspection.kind)
      elsif @copied_blob && @test_case.new_record?
        @test_case.case_file.attach(@copied_blob)
      end
    end

    def record_file(upload, kind)
      scan = FileScan.call(upload)
      return @errors << "The case study file was refused: the antivirus detected malicious content." if scan == "infected"

      upload.rewind
      blob = ActiveStorage::Blob.create_and_upload!(io: upload, filename: upload.original_filename,
                                                    content_type: CONTENT_TYPES.fetch(kind), identify: false)
      upload.rewind
      @test_case.case_file.attach(blob)
      @test_case.assign_attributes(case_file_blob_id: blob.id, case_file_kind: kind, case_file_bytes: blob.byte_size,
                                   case_file_sha256: Digest::SHA256.hexdigest(upload.read), scan_state: scan, scanned_at: @now)
    end

    CONTENT_TYPES = {
      "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      "pdf" => "application/pdf", "csv" => "text/csv"
    }.freeze

    # The form always sends the rubric section; a call without it (a new version made from the
    # previous one) copies the previous rubric, and an in-place save without it keeps the rubric.
    def write_criteria
      rows = if @params.key?(:criteria) then criteria_rows
             elsif @copied_criteria && @test_case.criteria.none? then @copied_criteria
             else return
             end
      return if @errors.any?

      @test_case.criteria.destroy_all
      rows.each_with_index { |row, i| @test_case.criteria.create!(row.merge(position: i + 1)) }
      @test_case.criteria.reset
    end

    def criteria_rows
      activities = @job.activities.to_h { |a| [a.id.to_s, a] }
      @params.rows(:criteria).first(CRITERIA_SLOTS).each_with_index.filter_map do |row, i|
        row = Briefs::Params.new(row.to_h.with_indifferent_access)
        next if %i[name weight anchor_1 anchor_3 anchor_5 activity_id].all? { |k| row.text(k).nil? }

        label = "Criterion #{i + 1}"
        weight = row.integer(:weight, @errors, "Weight of #{label.downcase}")
        activity = activities[row.text(:activity_id).to_s]
        @errors << "#{label}: choose the vacancy activity it tests." if activity.nil?
        @errors << "#{label}: the criterion name is required." if row.text(:name).nil?
        @errors << "#{label}: the weight is required, 1 to 100." if weight.nil? || !(1..100).cover?(weight)
        %i[anchor_1 anchor_3 anchor_5].each do |k|
          @errors << "#{label}: the example answer for score #{k.to_s[-1]} is required." if row.text(k).nil?
        end
        next if activity.nil?

        { activity_id: activity.id, activity_text: activity.description, name: row.text(:name).to_s, weight: weight.to_i,
          anchor_1: row.text(:anchor_1).to_s, anchor_3: row.text(:anchor_3).to_s, anchor_5: row.text(:anchor_5).to_s }
      end
    end

    def audit(before)
      after = TestCases::Snapshot.of(@test_case.reload)
      changes = after.each_with_object({}) { |(k, v), h| h[k] = [before[k], v] unless before[k] == v }
      return if changes.empty?

      JobBriefChange.create!(job: @job, actor: @actor, actor_role: @actor.role, step: "5",
                             changes_made: changes.merge("test_case_version" => [nil, @test_case.version]), created_at: @now)
    end
  end
end
