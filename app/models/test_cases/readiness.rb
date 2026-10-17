module TestCases
  # What a test version needs before HR may approve it (D60, plan §c, §d). Each problem is a
  # sentence that says what is missing and how to fix it, in English (docs/GLOSSARY-EN.md). The database
  # repeats the hard parts (weights 100, a recorded file, not infected, an answer type).
  module Readiness
    module_function

    # The portal-open hook (Portal::WindowChange#check_preconditions!, owned by the portal code):
    # a vacancy whose package runs no technical test (packages 1 and 2) is always ready; otherwise a
    # test must be in force: an approved competency bank (taken in the three-step application form,
    # slice B, 17 Oct 2026) or an approved uploaded case (taken after CV screening).
    def ready_for_open?(job)
      !Requirement.applies?(job) || QuestionBank.current_for(job).present? || TechnicalTestCase.current_for(job).present?
    end

    def refusal(job)
      return if ready_for_open?(job)

      "The technical test of this vacancy has nothing approved yet: approve the competency bank or the case document in brief step 5 before opening the portal."
    end

    def problems(test_case)
      list = []
      list << "Upload the case study file." unless test_case.case_file.attached? && test_case.case_file_blob_id
      list << "The case study file was flagged as malicious; upload another file." if test_case.scan_state == "infected"
      list << "Write the instructions for the applicant." if test_case.instructions.to_s.strip.empty?
      list << "Choose at least one answer type." if Array(test_case.answer_types).empty?
      criteria = test_case.criteria.to_a
      if criteria.empty?
        list << "Fill in at least one scoring criterion."
      elsif (total = criteria.sum(&:weight)) != 100
        list << "The criterion weights add up to #{total}%; they must total exactly 100%."
      end
      activity_ids = test_case.job.activities.pluck(:id)
      criteria.reject { |c| activity_ids.include?(c.activity_id) }.each do |c|
        list << "Criterion \"#{c.name}\" is linked to an activity that is no longer in the brief; choose its activity again."
      end
      list
    end
  end
end
