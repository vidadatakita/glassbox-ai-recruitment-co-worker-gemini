# frozen_string_literal: true

module Briefs
  # Everything a brief must satisfy before it is complete (blueprint §2.1, §2.3, §3.1 screen 2,
  # §7.1; D48, D49). Returns problems grouped by wizard step, each a sentence that says what is
  # wrong and how to fix it (one sentence, in the user's words). Empty list = the brief may be completed.
  #
  # Reads the saved job and its children only, so the screen, Briefs::Complete and the ad
  # approval gate all judge the same data.
  class BriefCheck
    Problem = Data.define(:step, :message)
    ACTIVITIES = (5..8)
    KNOCKOUTS = (2..3)

    def initialize(job)
      @job = job
    end

    def problems
      [*position_problems, *activity_problems, *requirement_problems, *compensation_problems,
       *package_problems, *stage_problems, *competency_problems, *test_case_problems]
    end

    def ok? = problems.empty?

    def for_step(step) = problems.select { |p| p.step == step }

    private

    attr_reader :job

    def problem(step, message) = Problem.new(step, message)

    # D60 slice 2: a package that runs S2 needs an approved technical-test version (step 5).
    def test_case_problems = TestCases::Requirement.problems(job).map { |message| problem(5, message) }

    def position_problems
      list = []
      list << problem(1, "Position is required.") if job.title.blank?
      list << problem(1, "Headcount is required, at least 1 person.") unless job.headcount.to_i.positive?
      list << problem(1, "Employment type is required.") if job.employment_type.blank?
      list
    end

    def activity_problems
      rows = job.activities.to_a
      list = []
      list << problem(2, "The 90-day target is required.") if job.success_90d.blank?
      unless ACTIVITIES.cover?(rows.size)
        list << problem(2, "There are #{rows.size} activities; enter 5 to 8 activities.")
      end
      shares = rows.map(&:share_percent)
      unless Totals.hundred?(shares)
        list << problem(2, "The activity time shares add up to #{shares.sum}%; they must add up to exactly 100%.")
      end
      list
    end

    def requirement_problems
      rows = job.requirements.to_a
      list = []
      list << problem(3, "Enter at least one must-have requirement.") if rows.none? { |r| r.tier == "wajib" }
      should = rows.select { |r| r.tier == "sebaiknya" }
      weights = should.map(&:weight)
      if should.any? && !Totals.hundred?(weights)
        list << problem(3, "The should-have weights add up to #{weights.compact.sum}%; they must add up to exactly 100%.")
      end
      count = job.knockout_questions.size
      unless KNOCKOUTS.cover?(count)
        list << problem(3, "There are #{count} knockout questions; enter 2 to 3 questions on must-have requirements.")
      end
      # Appendix D: flagged requirements wait for a person's decision. A stale or missing test is not a
      # problem here: Briefs::Complete runs it before judging, and the brief page offers the run.
      open = RequirementCheck.open_lines(job)
      if rows.any? && !RequirementCheck.stale?(job) && open.any?
        list << problem(3, "#{open.size} #{'requirement'.pluralize(open.size)} flagged by the discrimination test #{open.size == 1 ? 'waits' : 'wait'} for a decision: keep with a reason, use the neutral wording, or delete.")
      end
      list
    end

    def compensation_problems
      list = []
      if job.salary_min.nil? || job.salary_max.nil?
        list << problem(3, "The salary band (minimum and maximum) is required.")
      elsif job.salary_min > job.salary_max
        list << problem(3, "Minimum salary is higher than the maximum salary; swap the two figures.")
      end
      list << problem(3, "Enter at least one placement.") if job.placements.blank?
      list
    end

    def package_problems
      return [problem(4, "Package is required.")] if job.package.nil?

      [PackageAdvisor.override_problem(job.golongan, job.package, job.package_override_reason)].compact.map { |m| problem(4, m) }
    end

    def stage_problems
      return [] if job.package.nil?

      plan = job.stage_plan || {}
      codes = StagePlan.scored_codes(job.package)
      weights = codes.map { |c| plan.dig(c, "weight") }
      list = []
      unless Totals.hundred?(weights)
        list << problem(4, "The stage weights add up to #{weights.grep(Integer).sum}%; they must add up to exactly 100%.")
      end
      codes.each do |code|
        next if Totals.threshold?(plan.dig(code, "threshold"))

        list << problem(4, "The pass score of #{StagePlan::LABELS[code]} is required, a number from 0 to 100.")
      end
      list
    end

    def competency_problems
      rows = job.competencies.to_a
      list = rows.flat_map { |c| competency_row_problems(c) } + one_stage_problems(rows)
      message = Coverage.message(job.golongan, rows.map(&:layer))
      list << problem(4, message) if message
      list
    end

    # §2.1 "One competency, one stage": a row owns one stage, so the only way to assess one
    # competency twice is two rows with the same name (compared trimmed, case-insensitive) in
    # different stages (test engine F-02).
    def competency_key(name)
      name.to_s.unicode_normalize(:nfkc).gsub(/[[:space:]]+/, " ").strip.downcase
    end

    def one_stage_problems(rows)
      # Names are compared after NFKC normalisation and whitespace collapsing, because a
      # copy-pasted non-breaking space, a double space, a tab or a decomposed accent would
      # otherwise let one competency be scored in two stages (§2.1; engine finding F-06).
      rows.group_by { |c| competency_key(c.name) }.filter_map do |_, same|
        stages = same.map(&:stage_code).uniq
        next if stages.size < 2

        problem(4, "Competency \"#{same.first.name.strip}\" is assessed in #{stages.size} stages (#{stages.sort.join(', ')}). " \
                   "One competency is assessed in one stage only; delete one of the rows or give it a different name.")
      end
    end

    def competency_row_problems(comp)
      list = []
      if job.package && !StagePlan.scored_codes(job.package).include?(comp.stage_code)
        list << problem(4, "Competency \"#{comp.name}\" is assessed in #{StagePlan::LABELS[comp.stage_code]}, " \
                           "which this package does not run. Choose another stage.")
      end
      if [comp.anchor_1, comp.anchor_3, comp.anchor_5].any?(&:blank?)
        list << problem(4, "Competency \"#{comp.name}\" has no behaviour example yet for scores 1, 3 and 5.")
      end
      if Competency::INTERVIEW_STAGES.include?(comp.stage_code) && comp.questions.blank?
        list << problem(4, "Competency \"#{comp.name}\" is assessed in an interview; write its questions.")
      end
      list
    end
  end
end
