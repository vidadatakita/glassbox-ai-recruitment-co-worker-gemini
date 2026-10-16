module TestCases
  # What an audit row compares before and after a step-5 save (D49 (5) "every change recorded").
  # The case file is identified by its SHA-256, never by its content.
  module Snapshot
    module_function

    def of(test_case)
      return {} if test_case.nil? || test_case.new_record?

      { "instructions" => test_case.instructions, "time_limit_minutes" => test_case.time_limit_minutes,
        "answer_types" => test_case.answer_types, "case_file_sha256" => test_case.case_file_sha256,
        "new_version_reason" => test_case.new_version_reason,
        "criteria" => test_case.criteria.map { |c| [c.activity_id, c.name, c.weight, c.anchor_1, c.anchor_3, c.anchor_5] } }
    end
  end
end
