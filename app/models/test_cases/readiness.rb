module TestCases
  # What a test version needs before HR may approve it (D60, plan §c, §d). Each problem is a
  # sentence that says what is missing and how to fix it, in English (docs/GLOSSARY-EN.md). The database
  # repeats the hard parts (weights 100, a recorded file, not infected, an answer type).
  module Readiness
    module_function

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
