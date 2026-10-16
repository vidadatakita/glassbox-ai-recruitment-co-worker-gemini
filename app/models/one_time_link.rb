require "digest"

# A link sent to someone without an account (blueprint §2.1). Only the SHA-256 digest of the
# token is stored, so a database leak does not leak working links.
#
# Candidate status links (D36) have no N-day expiry: they end when the application's data is
# deleted at retention, when consent is withdrawn, or when a new link is issued (revoked_at).
class OneTimeLink < ApplicationRecord
  # interviewer_score: AI Builder Cup step 07, an interviewer without an account scores (InterviewerInvite).
  PURPOSES = %w[candidate_status interviewer_score].freeze

  belongs_to :subject, polymorphic: true
  has_many :link_opens, dependent: :restrict_with_exception

  validates :purpose, inclusion: { in: PURPOSES }
  validates :token_digest, presence: true, uniqueness: true

  def self.digest(token) = Digest::SHA256.hexdigest(token.to_s)

  # Creates a link and returns [link, raw_token]. The raw token exists only in this return value.
  def self.issue!(subject:, purpose:, expires_at: nil)
    token = SecureRandom.urlsafe_base64(32)
    link = create!(subject:, purpose:, expires_at:, token_digest: digest(token))
    [link, token]
  end

  # The live link for a token, or nil. A tampered, unknown, revoked or expired token all answer
  # nil, so the caller shows one "Link tidak berlaku" page and never another record.
  def self.live(purpose, token, now: Time.current)
    return nil if token.blank?

    link = find_by(purpose:, token_digest: digest(token))
    link if link&.live?(now)
  end

  def live?(now = Time.current)
    revoked_at.nil? && (expires_at.nil? || now < expires_at)
  end

  def revoke!(now = Time.current)
    update!(revoked_at: now) if revoked_at.nil?
  end
end
