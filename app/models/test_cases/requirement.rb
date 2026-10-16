module TestCases
  # D60 default (accepted 16:36): the technical test runs in the apply flow only when the job's
  # package runs S2 (packages 3 and up). Then the brief has a step 5 "Technical test" and cannot be
  # completed without an approved test version.
  module Requirement
    module_function

    def applies?(job) = job.package.present? && Briefs::StagePlan.codes(job.package).include?("S2")

    def problems(job)
      return [] unless applies?(job)

      current = TechnicalTestCase.current_for(job)
      return orphan_problems(job, current) if current

      latest = TechnicalTestCase.latest_for(job)
      if latest.nil?
        ["The technical test has not been created. The consultant uploads the case study and its rubric in step 5, then HR approves it."]
      else
        ["Technical test version #{latest.version} has not been approved by HR. HR approves it in step 5."]
      end
    end

    # Test engine 07 F-05: the version in force must test activities that are still in the brief.
    # Step-2 saves keep activity ids (Briefs::SaveStep#stable_activity_rows); this catches a row the
    # user really removed, and asks for a new version instead of a rubric that tests nothing.
    def orphan_problems(job, current)
      live = job.activities.pluck(:id)
      return [] if current.criteria.all? { |c| live.include?(c.activity_id) }

      ["The technical test rubric refers to a deleted activity; create a new version."]
    end
  end
end
