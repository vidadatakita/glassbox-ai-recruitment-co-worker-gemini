# One criterion of a test version's rubric (D60, plan §c): a weight (whole %, the version's weights
# sum to 100 before approval), the 1/3/5 anchors like the competency map, and the job activity it
# tests. activity_text is a copy of the activity at the time of the save, so a later brief edit
# never changes what a started test was built from; activity_id is kept to check the link.
class TestCaseCriterion < ApplicationRecord
  self.table_name = "test_case_criteria"

  belongs_to :test_case, class_name: "TechnicalTestCase", inverse_of: :criteria

  validates :name, :activity_text, :anchor_1, :anchor_3, :anchor_5, presence: true
  validates :weight, numericality: { only_integer: true, in: 1..100 }
end
