# One row per opening of a status link (D36): the link and the time, nothing about the device.
class LinkOpen < ApplicationRecord
  include AppendOnly

  belongs_to :one_time_link
end
