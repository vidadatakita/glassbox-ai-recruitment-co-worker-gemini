class AppointmentChange < ApplicationRecord
  include AppendOnly

  belongs_to :appointment
end
