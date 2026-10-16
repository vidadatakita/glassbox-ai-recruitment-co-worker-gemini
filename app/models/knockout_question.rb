# A yes/no must-have question asked before any personal data (P8, rule 16). "Tidak" means the
# candidate cannot qualify.
class KnockoutQuestion < ApplicationRecord
  belongs_to :job
  # Feature 03: a question entered in the job form is derived from one "wajib" requirement.
  # Optional, because the questions of the two demo jobs predate the form.
  belongs_to :requirement, optional: true

  validates :text, :position, presence: true
end
