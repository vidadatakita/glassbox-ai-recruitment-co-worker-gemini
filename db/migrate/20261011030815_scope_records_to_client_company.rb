# Multi-tenant groundwork (TENANCY=multi): every record a client user (HR PIC, owner) acts on must
# belong to their own client company. The app scopes every staff query through the job
# (Job.visible_to); this migration adds the database side:
#   - jobs.client_company_id NOT NULL, and HR PIC / owner always have a company;
#   - user_in_job_company(): the HR PIC / owner triggers (progression choice, salary agreement,
#     Rekomendasi User) refuse a user of another company, not only another role;
#   - link_requests.job_id, so an unmatched "Minta link baru" reaches only that job's company;
#   - per-company screen settings, consent texts and their audit: client_company_id NULL is the
#     install-wide default, a company row overrides it; uniqueness per company.
class ScopeRecordsToClientCompany < ActiveRecord::Migration[8.1]
  def up
    change_column_null :jobs, :client_company_id, false
    add_check_constraint :users, "role NOT IN ('hr_pic', 'owner') OR client_company_id IS NOT NULL", name: "users_client_roles_have_company"

    execute <<~SQL
      CREATE FUNCTION user_in_job_company(user_id bigint, job_id bigint) RETURNS boolean LANGUAGE sql STABLE AS $$
        SELECT u.client_company_id IS NULL OR u.client_company_id = j.client_company_id
        FROM users u, jobs j WHERE u.id = user_id AND j.id = job_id
      $$;

      CREATE OR REPLACE FUNCTION enforce_progression_chooser() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF (SELECT role FROM users WHERE id = NEW.actor_id) IS DISTINCT FROM 'hr_pic' THEN
          RAISE EXCEPTION 'progression choice refused: only the HR PIC chooses (AI Builder Cup step 06)'
            USING ERRCODE = 'check_violation';
        END IF;
        IF NOT user_in_job_company(NEW.actor_id, (SELECT s.job_id FROM participations p JOIN stages s ON s.id = p.stage_id WHERE p.id = NEW.participation_id)) THEN
          RAISE EXCEPTION 'progression choice refused: the HR PIC belongs to another company' USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$;

      CREATE OR REPLACE FUNCTION enforce_salary_decider() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF (SELECT role FROM users WHERE id = NEW.decided_by_id) IS DISTINCT FROM 'owner' THEN
          RAISE EXCEPTION 'salary agreement refused: only the owner decides (AI Builder Cup step 08)'
            USING ERRCODE = 'check_violation';
        END IF;
        IF NOT user_in_job_company(NEW.decided_by_id, (SELECT job_id FROM job_applications WHERE id = NEW.job_application_id)) THEN
          RAISE EXCEPTION 'salary agreement refused: the owner belongs to another company' USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$;

      CREATE OR REPLACE FUNCTION enforce_user_recommendation_actor() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF (SELECT role FROM users WHERE id = NEW.entered_by_id) IS DISTINCT FROM 'hr_pic' THEN
          RAISE EXCEPTION 'user recommendation refused: only the HR PIC enters it (D62 h6)'
            USING ERRCODE = 'check_violation';
        END IF;
        IF NOT user_in_job_company(NEW.entered_by_id, (SELECT job_id FROM job_applications WHERE id = NEW.job_application_id)) THEN
          RAISE EXCEPTION 'user recommendation refused: the HR PIC belongs to another company' USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$;
    SQL

    add_reference :link_requests, :job, foreign_key: true

    %i[system_settings consent_templates setting_changes].each do |table|
      add_reference table, :client_company, foreign_key: true
    end
    remove_index :system_settings, :key
    execute "CREATE UNIQUE INDEX index_system_settings_on_company_and_key ON system_settings (client_company_id, key) NULLS NOT DISTINCT"
    remove_index :consent_templates, :version
    execute "CREATE UNIQUE INDEX index_consent_templates_on_company_and_version ON consent_templates (client_company_id, version) NULLS NOT DISTINCT"
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
