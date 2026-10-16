require "digest"

# One-time code that unlocks the offer tab (D36): the offer carries the salary, so a forwarded
# status link alone must not show it. The code goes to the applicant's email; only its digest
# is stored. Valid for CODE_LIFETIME, usable once.
class OfferAccessCode < ApplicationRecord
  # 15 minutes: long enough to switch to the mail app and back on a slow phone, short enough
  # that a code read later from a shared inbox is dead. Builder default, recorded in the
  # feature record for direction to confirm.
  CODE_LIFETIME = 15.minutes

  belongs_to :job_application

  def self.digest(code) = Digest::SHA256.hexdigest("offer-code:#{code}")

  def self.issue!(job_application, now: Time.current)
    # At most one live code: a new code retires the unused older ones (test engine F10).
    where(job_application:, used_at: nil).where("expires_at > ?", now).update_all(used_at: now, updated_at: now)
    code = format("%06d", SecureRandom.random_number(1_000_000))
    record = create!(job_application:, code_digest: digest(code), expires_at: now + CODE_LIFETIME)
    [record, code]
  end

  # Consumes a matching live code for the application; true only once.
  def self.redeem(job_application, code, now: Time.current)
    return false if code.blank?

    updated = where(job_application:, code_digest: digest(code.to_s.strip), used_at: nil)
              .where("expires_at > ?", now)
              .update_all(used_at: now, updated_at: now)
    updated.positive?
  end
end
