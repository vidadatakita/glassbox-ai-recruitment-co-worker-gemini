# Feature 06, third line of defence (ADR 0004; test engine run 3): the model reports, by CATEGORY
# only, when it notices a protected attribute in the redacted CV text. Such a result always goes to
# the reviewer, and the categories feed the redactor's word lists.
#
# Additive: a new column with a default. The screening_reviews reason CHECK is WIDENED with one more
# allowed value ("protected_attribute"); every row valid before stays valid.
class AddProtectedAttributeFlag < ActiveRecord::Migration[8.1]
  CATEGORIES = %w[religion gender age marital_status ethnicity address appearance family health other].freeze

  def up
    add_column :screening_results, :protected_attribute_categories, :string, array: true, null: false, default: []
    remove_check_constraint :screening_reviews, name: "screening_reviews_reason"
    add_check_constraint :screening_reviews,
                         "reason IN ('elimination','sample','unverified','calibration_disagreement','protected_attribute')",
                         name: "screening_reviews_reason"
  end

  def down
    remove_check_constraint :screening_reviews, name: "screening_reviews_reason"
    add_check_constraint :screening_reviews, "reason IN ('elimination','sample','unverified','calibration_disagreement')",
                         name: "screening_reviews_reason"
    remove_column :screening_results, :protected_attribute_categories
  end
end
