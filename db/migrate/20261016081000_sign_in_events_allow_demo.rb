# frozen_string_literal: true

# A5 (16 Oct 2026): the demo door signs a visitor into a seeded account and logs it like every other
# sign-in, with auth_method "demo", so the audit trail shows which sessions were demo sessions. The
# database CHECK on sign_in_events.auth_method listed only password and google and would refuse the
# row (PG::CheckViolation), which would make the door fail after the session was already created.
class SignInEventsAllowDemo < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      ALTER TABLE sign_in_events DROP CONSTRAINT sign_in_events_auth_method;
      ALTER TABLE sign_in_events ADD CONSTRAINT sign_in_events_auth_method
        CHECK (auth_method IN ('password', 'google', 'demo'));
    SQL
  end

  def down
    execute <<~SQL
      ALTER TABLE sign_in_events DROP CONSTRAINT sign_in_events_auth_method;
      ALTER TABLE sign_in_events ADD CONSTRAINT sign_in_events_auth_method
        CHECK (auth_method IN ('password', 'google'));
    SQL
  end
end
