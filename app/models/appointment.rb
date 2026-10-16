# A scheduled test or interview for one participation (BP §3.6 B3). Times are stored in UTC and
# shown in WIB. Changing the time sets the confirmation back to pending and logs the old time.
class Appointment < ApplicationRecord
  MODES = { "onsite" => "In person (on site)", "video" => "Video", "phone" => "Phone" }.freeze
  CONFIRMATIONS = %w[pending confirmed reschedule_requested].freeze

  belongs_to :participation
  delegate :job, to: :participation # the record's company is its job's (BaseController#org_find)
  has_many :appointment_changes, dependent: :restrict_with_exception

  validates :starts_at, :ends_at, :place_or_link, :contact, presence: true
  validates :mode, inclusion: { in: MODES.keys }
  validates :confirmation, inclusion: { in: CONFIRMATIONS }
  validate :ends_after_start

  private

  def ends_after_start
    errors.add(:ends_at, "must be after the start time") if starts_at && ends_at && ends_at <= starts_at
  end
end
