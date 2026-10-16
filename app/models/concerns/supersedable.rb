# A correction is a NEW row pointing at the row it replaces (supersedes_id). "Current" rows
# are the ones no other row supersedes. Statistics and decisions read current rows only
# (blueprint §2.2 rule 9).
module Supersedable
  extend ActiveSupport::Concern
  include AppendOnly

  included do
    belongs_to :supersedes, class_name: name, optional: true
    scope :current, -> { where.not(id: unscoped.where.not(supersedes_id: nil).select(:supersedes_id)) }
  end
end
