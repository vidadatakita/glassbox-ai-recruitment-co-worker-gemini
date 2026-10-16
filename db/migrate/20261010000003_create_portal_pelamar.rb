# Portal Pelamar (decisions D28, D32, D33, D35, D36; blueprint v1.4 §3.6).
#
# Adds the minimum of Plans 2 and 4 the portal needs: one client company, the candidate,
# consent, one-time links, the application window log, appointments, offers and objections.
# Append-only tables reuse forbid_update_delete() from MakeScoringRecordsAppendOnly.
class CreatePortalPelamar < ActiveRecord::Migration[8.1]
  APPEND_ONLY = %w[application_window_events appointment_changes setting_changes link_opens consent_templates].freeze

  def up
    create_table :client_companies do |t|
      t.string :name, null: false
      t.string :address, null: false
      t.string :city, null: false
      # Company-domain address shown in the Lamar trust block (BP §3.6 B2).
      t.string :contact_email, null: false
      t.timestamps
    end

    # ONP-1 (b): with TENANCY=single the database refuses a second company. The tenancy value
    # reaches PostgreSQL as the session variable glassbox.tenancy (config/database.yml), so the
    # rule holds for raw SQL and consoles too. LOCK serialises two concurrent first inserts.
    execute <<~SQL
      CREATE FUNCTION enforce_single_tenant() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF current_setting('glassbox.tenancy', true) = 'single' THEN
          LOCK TABLE client_companies IN SHARE ROW EXCLUSIVE MODE;
          IF EXISTS (SELECT 1 FROM client_companies) THEN
            RAISE EXCEPTION 'TENANCY=single allows one client company'
              USING ERRCODE = 'unique_violation';
          END IF;
        END IF;
        RETURN NEW;
      END;
      $$;
      CREATE TRIGGER client_companies_single_tenant BEFORE INSERT ON client_companies
      FOR EACH ROW EXECUTE FUNCTION enforce_single_tenant();
    SQL

    change_table :jobs do |t|
      t.references :client_company, foreign_key: true
      t.string :public_code
      t.string :location
      # Integer rupiah, monthly gross (blueprint §2.1). Never a float.
      t.bigint :salary_min
      t.bigint :salary_max
      t.boolean :show_salary, null: false, default: false
      # G1 / D17: the ad hides the company name.
      t.boolean :confidential, null: false, default: false
      t.datetime :ad_approved_at
      t.bigint :ad_approved_by_id
    end
    add_index :jobs, :public_code, unique: true
    add_check_constraint :jobs, "salary_min IS NULL OR salary_max IS NULL OR salary_min <= salary_max", name: "jobs_salary_band_order"

    # The date by which the candidate hears the result of a stage (P13 "always a next date").
    add_column :stages, :results_due_on, :date

    create_table :knockout_questions do |t|
      t.references :job, null: false, foreign_key: true
      t.integer :position, null: false
      t.string :text, null: false
      t.timestamps
    end
    add_index :knockout_questions, %i[job_id position], unique: true

    create_table :candidates do |t|
      t.string :name, null: false
      t.string :email, null: false
      t.string :phone, null: false
      t.timestamps
    end

    # D35: every edit is a new version; a version is never changed after insert.
    create_table :consent_templates do |t|
      t.string :version, null: false
      t.text :controller_identity, null: false
      t.text :legal_basis, null: false
      t.text :purpose, null: false
      t.text :data_types, null: false
      t.text :collected_items, null: false
      t.text :processing_duration, null: false
      t.text :rights, null: false
      t.datetime :effective_from, null: false
      t.bigint :created_by_id
      t.datetime :created_at, null: false
    end
    add_index :consent_templates, :version, unique: true
    # Pasal 21(1) b and d: purpose cannot be emptied (retention comes from the setting).
    add_check_constraint :consent_templates, "length(btrim(purpose)) > 0", name: "consent_templates_purpose_present"

    change_table :job_applications do |t|
      t.references :candidate, foreign_key: true
      t.string :channel_code
      t.jsonb :knockout_answers, null: false, default: {}
      t.datetime :consent_at
      t.references :consent_template, foreign_key: true
      # The retention period in force when the candidate agreed (days after the job closes).
      t.integer :consent_retention_days
      t.datetime :consent_withdrawn_at
    end
    add_check_constraint :job_applications,
      "candidate_id IS NULL OR (consent_at IS NOT NULL AND consent_template_id IS NOT NULL AND consent_retention_days > 0)",
      name: "job_applications_consent_recorded"

    create_table :one_time_links do |t|
      t.string :token_digest, null: false
      t.string :purpose, null: false
      t.references :subject, polymorphic: true, null: false
      # D36: status links have no N-day expiry; they end at retention deletion, consent
      # withdrawal or re-issue (revoked_at). The column stays for other purposes.
      t.datetime :expires_at
      t.datetime :used_at
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :one_time_links, :token_digest, unique: true

    # D36: every open of a status link is logged (link id and time only; no IP, no agent).
    create_table :link_opens do |t|
      t.references :one_time_link, null: false, foreign_key: true
      t.datetime :opened_at, null: false
    end

    # D36: one-time code for the offer tab, sent to the applicant's email.
    create_table :offer_access_codes do |t|
      t.references :job_application, null: false, foreign_key: true
      t.string :code_digest, null: false
      t.datetime :expires_at, null: false
      t.datetime :used_at
      t.timestamps
    end

    create_table :link_requests do |t|
      t.references :job_application, foreign_key: true
      t.string :job_code
      t.string :contact, null: false
      t.datetime :handled_at
      t.bigint :handled_by_id
      t.timestamps
    end

    # §3.6 C: window state is DERIVED from these rows plus closes_at, quota and the count.
    # Only manual actions are written; an automatic close is computed, never stored.
    create_table :application_window_events do |t|
      t.references :job, null: false, foreign_key: true
      t.string :action, null: false
      t.datetime :closes_at
      t.integer :quota
      t.text :reason
      t.bigint :actor_id, null: false
      t.string :actor_role, null: false
      t.datetime :created_at, null: false
    end
    add_check_constraint :application_window_events, "action IN ('open','close','reopen')", name: "window_events_action"
    add_check_constraint :application_window_events, "action <> 'reopen' OR length(btrim(coalesce(reason,''))) > 0", name: "window_events_reopen_reason"
    add_check_constraint :application_window_events, "quota IS NULL OR quota > 0", name: "window_events_quota_positive"

    create_table :appointments do |t|
      t.references :participation, null: false, foreign_key: true, index: { unique: true }
      t.datetime :starts_at, null: false
      t.datetime :ends_at, null: false
      t.string :mode, null: false
      t.string :place_or_link, null: false
      t.string :bring
      t.string :contact, null: false
      t.string :confirmation, null: false, default: "pending"
      t.text :reschedule_reason
      t.timestamps
    end
    add_check_constraint :appointments, "mode IN ('onsite','video','phone')", name: "appointments_mode"
    add_check_constraint :appointments, "confirmation IN ('pending','confirmed','reschedule_requested')", name: "appointments_confirmation"
    add_check_constraint :appointments, "ends_at > starts_at", name: "appointments_order"

    create_table :appointment_changes do |t|
      t.references :appointment, null: false, foreign_key: true
      t.datetime :old_starts_at
      t.datetime :new_starts_at, null: false
      t.bigint :actor_id, null: false
      t.datetime :created_at, null: false
    end

    create_table :offer_documents do |t|
      t.references :job_application, null: false, foreign_key: true
      t.integer :version, null: false
      t.datetime :start_at, null: false
      t.date :valid_until, null: false
      t.text :day_one_notes, null: false
      t.bigint :uploaded_by_id, null: false
      t.string :response
      t.text :response_reason
      t.datetime :responded_at
      t.datetime :followed_up_at
      t.bigint :followed_up_by_id
      t.timestamps
    end
    add_index :offer_documents, %i[job_application_id version], unique: true
    # An offer is accepted at most once per application (BP §3.6 D).
    add_index :offer_documents, :job_application_id, unique: true, where: "response = 'accepted'", name: "offer_documents_one_acceptance"
    add_check_constraint :offer_documents, "response IS NULL OR response IN ('accepted','declined')", name: "offer_documents_response"
    add_check_constraint :offer_documents, "response IS DISTINCT FROM 'declined' OR length(btrim(coalesce(response_reason,''))) > 0", name: "offer_documents_decline_reason"

    create_table :objections do |t|
      t.references :participation, null: false, foreign_key: true
      t.text :text, null: false
      t.datetime :received_at, null: false
      t.bigint :answered_by_id
      t.string :outcome
      t.text :answer
      t.datetime :answered_at
      t.timestamps
    end
    # One open objection per participation.
    add_index :objections, :participation_id, unique: true, where: "answered_at IS NULL", name: "objections_one_open"
    add_check_constraint :objections, "outcome IS NULL OR outcome IN ('upheld','not_upheld')", name: "objections_outcome"

    # Every email to a candidate, sent or failed (ONP-12: a failed send is shown in the work
    # queue, never only in a log). No message body is stored, only what and to which application.
    create_table :mail_deliveries do |t|
      t.references :job_application, null: false, foreign_key: true
      t.string :kind, null: false
      t.string :status, null: false
      t.string :error_class
      t.text :error_message
      t.datetime :handled_at
      t.timestamps
    end
    add_check_constraint :mail_deliveries, "status IN ('sent','failed')", name: "mail_deliveries_status"

    create_table :system_settings do |t|
      t.string :key, null: false
      t.string :value, null: false
      t.timestamps
    end
    add_index :system_settings, :key, unique: true

    create_table :setting_changes do |t|
      t.string :key, null: false
      t.string :old_value
      t.string :new_value, null: false
      t.bigint :actor_id, null: false
      t.datetime :created_at, null: false
    end

    APPEND_ONLY.each do |table|
      execute <<~SQL
        CREATE TRIGGER #{table}_append_only BEFORE UPDATE OR DELETE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION forbid_update_delete();
        CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON #{table}
        FOR EACH STATEMENT EXECUTE FUNCTION forbid_truncate();
      SQL
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
