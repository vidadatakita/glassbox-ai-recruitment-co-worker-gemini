# Who signed in to a staff account, how and when (D52: "log sign-ins (who, how, when) without
# tokens"). Also refused Google attempts, with the email DOMAIN only: a refused address may belong
# to a candidate or a stranger, and a full address in an audit table is personal data with no
# purpose here. Append-only (database trigger).
class SignInEvent < ApplicationRecord
  include AppendOnly

  belongs_to :user, optional: true

  # "demo": the no-login door of the public demo (A5), a real session on a seeded account.
  validates :auth_method, inclusion: { in: %w[password google demo] }
  validates :outcome, inclusion: { in: %w[success refused] }

  def self.record!(request:, auth_method:, outcome:, user: nil, reason: nil, email: nil)
    create!(user:, auth_method:, outcome:, reason:,
            email_domain: email.to_s.split("@", 2)[1]&.downcase&.truncate(255),
            ip_address: request.remote_ip, user_agent: request.user_agent.to_s.truncate(255),
            created_at: Time.current)
  end
end
