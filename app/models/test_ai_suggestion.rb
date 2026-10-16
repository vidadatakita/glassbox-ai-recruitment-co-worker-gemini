# The AI's proposed rating per rubric criterion for one technical-test answer (TechnicalTests::AiScore).
# A proposal the reviewer reads, edits and confirms; never a score by itself. Never edited.
#
# payload: { "criteria" => [{ "criterion_id", "rating" (1-5), "reason", "quote" }], "summary" }
class TestAiSuggestion < ApplicationRecord
  include AppendOnly

  belongs_to :test_attempt
  belongs_to :actor, class_name: "User"

  def criteria = payload.fetch("criteria", [])
  def for_criterion(id) = criteria.find { |c| c["criterion_id"] == id }
end
