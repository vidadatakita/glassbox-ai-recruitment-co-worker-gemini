# "Ask AI" audit: a question, the read function that answered it, the answer shown. Append-only.
class DataQuestion < ApplicationRecord
  include AppendOnly

  belongs_to :user
end
