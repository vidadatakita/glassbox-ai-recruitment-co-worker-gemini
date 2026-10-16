# D52: the four Google integrations (login, mail, storage, calendar). Additive only.
#
# - google_integration_events: one row per health result (the check task, a calendar sync, a
#   Google login provider error). Pengaturan Sistem reads the latest row per integration to say
#   "Aktif" or "Gagal terakhir: <waktu>". Append-only, like every other log table here, so a
#   failure cannot be quietly erased after the fact.
# - sign_in_events: who signed in, how (password or Google) and when; also refused Google
#   attempts (with the email DOMAIN only, never the full address, and never a token). Sessions
#   are destroyed on logout, so the sessions table cannot serve as this log.
# - appointments.calendar_*: the Google Calendar event id and the last sync outcome, shown on the
#   appointment ("Undangan kalender gagal dikirim") and retried from there.
class CreateGoogleIntegrations < ActiveRecord::Migration[8.1]
  def up
    create_table :google_integration_events do |t|
      t.string :integration, null: false
      t.string :outcome, null: false
      t.string :source, null: false
      t.string :error_class
      t.string :message, limit: 500
      t.datetime :created_at, null: false
    end
    add_index :google_integration_events, %i[integration created_at]

    create_table :sign_in_events do |t|
      t.references :user, foreign_key: true
      t.string :auth_method, null: false
      t.string :outcome, null: false
      t.string :reason
      t.string :email_domain
      t.string :ip_address
      t.string :user_agent
      t.datetime :created_at, null: false
    end

    add_column :appointments, :calendar_event_id, :string
    add_column :appointments, :calendar_status, :string
    add_column :appointments, :calendar_error, :string, limit: 500
    add_column :appointments, :calendar_synced_at, :datetime

    execute <<~SQL
      ALTER TABLE google_integration_events
        ADD CONSTRAINT google_integration_events_integration CHECK (integration IN ('login', 'mail', 'storage', 'calendar')),
        ADD CONSTRAINT google_integration_events_outcome CHECK (outcome IN ('ok', 'failed')),
        ADD CONSTRAINT google_integration_events_source CHECK (source IN ('check', 'sync', 'login'));
      ALTER TABLE sign_in_events
        ADD CONSTRAINT sign_in_events_auth_method CHECK (auth_method IN ('password', 'google')),
        ADD CONSTRAINT sign_in_events_outcome CHECK (outcome IN ('success', 'refused')),
        ADD CONSTRAINT sign_in_events_success_has_user CHECK (outcome <> 'success' OR user_id IS NOT NULL);
      ALTER TABLE appointments
        ADD CONSTRAINT appointments_calendar_status CHECK (calendar_status IS NULL OR calendar_status IN ('synced', 'failed', 'cancelled'));

      CREATE TRIGGER google_integration_events_append_only BEFORE UPDATE OR DELETE ON google_integration_events
        FOR EACH ROW EXECUTE FUNCTION forbid_update_delete();
      CREATE TRIGGER google_integration_events_no_truncate BEFORE TRUNCATE ON google_integration_events
        FOR EACH STATEMENT EXECUTE FUNCTION forbid_truncate();
      CREATE TRIGGER sign_in_events_append_only BEFORE UPDATE OR DELETE ON sign_in_events
        FOR EACH ROW EXECUTE FUNCTION forbid_update_delete();
      CREATE TRIGGER sign_in_events_no_truncate BEFORE TRUNCATE ON sign_in_events
        FOR EACH STATEMENT EXECUTE FUNCTION forbid_truncate();
    SQL
  end

  def down
    remove_column :appointments, :calendar_synced_at
    remove_column :appointments, :calendar_error
    remove_column :appointments, :calendar_status
    remove_column :appointments, :calendar_event_id
    drop_table :sign_in_events
    drop_table :google_integration_events
  end
end
