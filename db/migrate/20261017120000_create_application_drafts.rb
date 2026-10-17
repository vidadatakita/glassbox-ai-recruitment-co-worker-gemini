# frozen_string_literal: true

# Three-step application with the competency test (Vida, 17 Oct 2026; FLOW §7): 1 personal details,
# knockout questions and consent, 2 CV, 3 the test (one timer, answers saved as typed), then Submit.
# Built BESIDE the two-step form (lamar): only a vacancy with an approved question bank uses it.
#
# The application in progress is a DRAFT in its own table, never a job_applications row, so screening,
# counts and reports keep seeing submitted applications only. Submit turns the draft into an
# application through Portal::SubmitApplication (the same checks as the two-step form) and the draft
# keeps the test (the draw and the answers) linked to it; its personal fields are then cleared.
# An unsubmitted draft is deleted after the vacancy's portal closes (ApplicationDrafts::Purge).
#
# The database repeats what must survive a bug: one draw per draft that never changes once the test
# started, the deadline fixed at start, no answer after the deadline (plus the grace) or after submit.
class CreateApplicationDrafts < ActiveRecord::Migration[8.1]
  def up
    create_table :application_drafts do |t|
      t.references :job, null: false, foreign_key: true
      # SHA-256 of the secret in the applicant's link; the secret itself is never stored.
      t.string :token_digest, null: false
      t.string :name
      t.string :email
      t.string :phone
      t.string :domicile_city
      t.bigint :expected_salary_min
      t.bigint :expected_salary_max
      t.jsonb :knockout_answers, null: false, default: {}
      t.references :consent_template, null: false, foreign_key: true
      t.integer :consent_retention_days, null: false
      t.datetime :consent_at, null: false
      t.string :channel_code
      t.references :question_bank, null: false, foreign_key: true
      # The questions this applicant draws, in the order shown: technical first, then role.
      t.bigint :draw, array: true, null: false, default: []
      t.integer :time_limit_minutes, null: false
      t.integer :grace_seconds, null: false, default: 120
      t.datetime :test_started_at
      t.datetime :test_due_at
      t.datetime :submitted_at
      t.references :job_application, foreign_key: true, index: { unique: true }
      t.timestamps
    end
    add_index :application_drafts, :token_digest, unique: true
    execute <<~SQL
      ALTER TABLE application_drafts
        ADD CONSTRAINT application_drafts_time_limit_range CHECK (time_limit_minutes BETWEEN 1 AND 60),
        ADD CONSTRAINT application_drafts_grace_range CHECK (grace_seconds BETWEEN 0 AND 600),
        ADD CONSTRAINT application_drafts_test_pair CHECK ((test_started_at IS NULL) = (test_due_at IS NULL)),
        ADD CONSTRAINT application_drafts_due_from_limit CHECK (
          test_started_at IS NULL OR test_due_at = test_started_at + make_interval(mins => time_limit_minutes)),
        ADD CONSTRAINT application_drafts_started_has_draw CHECK (test_started_at IS NULL OR cardinality(draw) >= 1),
        ADD CONSTRAINT application_drafts_submitted_has_application CHECK ((submitted_at IS NULL) = (job_application_id IS NULL))
    SQL

    create_table :draft_answers do |t|
      t.references :application_draft, null: false, foreign_key: true
      t.references :bank_question, null: false, foreign_key: true
      t.integer :choice_index
      t.text :answer_text
      # Filled at Submit for a multiple-choice question: the scoring is the bank's answer key, by
      # rule, never the AI.
      t.boolean :correct
      t.datetime :saved_at, null: false
      t.timestamps
    end
    add_index :draft_answers, %i[application_draft_id bank_question_id], unique: true
    execute <<~SQL
      ALTER TABLE draft_answers
        ADD CONSTRAINT draft_answers_one_kind CHECK (choice_index IS NULL OR answer_text IS NULL),
        ADD CONSTRAINT draft_answers_choice_range CHECK (choice_index IS NULL OR choice_index BETWEEN 0 AND 5)
    SQL

    execute <<~SQL
      CREATE FUNCTION enforce_application_draft() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF OLD.test_started_at IS NOT NULL AND (NEW.draw <> OLD.draw OR NEW.test_started_at <> OLD.test_started_at
            OR NEW.test_due_at <> OLD.test_due_at OR NEW.time_limit_minutes <> OLD.time_limit_minutes
            OR NEW.question_bank_id <> OLD.question_bank_id OR NEW.grace_seconds <> OLD.grace_seconds) THEN
          RAISE EXCEPTION 'application_drafts: the draw and the deadline never change once the test started'
            USING ERRCODE = 'restrict_violation';
        END IF;
        IF OLD.submitted_at IS NOT NULL AND (NEW.submitted_at IS DISTINCT FROM OLD.submitted_at
            OR NEW.job_application_id IS DISTINCT FROM OLD.job_application_id) THEN
          RAISE EXCEPTION 'application_drafts: a submitted draft stays linked to its application'
            USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN NEW;
      END;
      $$;

      CREATE TRIGGER application_drafts_guard BEFORE UPDATE ON application_drafts
        FOR EACH ROW EXECUTE FUNCTION enforce_application_draft();

      CREATE FUNCTION enforce_draft_answer() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE d application_drafts%ROWTYPE;
      BEGIN
        SELECT * INTO d FROM application_drafts WHERE id = NEW.application_draft_id;
        -- Only the correct flag may be written after submit (the scoring at Submit itself).
        IF TG_OP = 'UPDATE' AND NEW.choice_index IS NOT DISTINCT FROM OLD.choice_index
           AND NEW.answer_text IS NOT DISTINCT FROM OLD.answer_text AND NEW.saved_at = OLD.saved_at THEN
          RETURN NEW;
        END IF;
        IF d.submitted_at IS NOT NULL THEN
          RAISE EXCEPTION 'draft_answers: the application is submitted; answers are final' USING ERRCODE = 'restrict_violation';
        END IF;
        IF d.test_started_at IS NULL OR NOT (NEW.bank_question_id = ANY (d.draw)) THEN
          RAISE EXCEPTION 'draft_answers: only a question drawn for this applicant, after the test started'
            USING ERRCODE = 'restrict_violation';
        END IF;
        IF NEW.saved_at > d.test_due_at + make_interval(secs => d.grace_seconds) THEN
          RAISE EXCEPTION 'draft_answers: the time for the test is over' USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN NEW;
      END;
      $$;

      CREATE TRIGGER draft_answers_guard BEFORE INSERT OR UPDATE ON draft_answers
        FOR EACH ROW EXECUTE FUNCTION enforce_draft_answer();
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS draft_answers_guard ON draft_answers"
    execute "DROP TRIGGER IF EXISTS application_drafts_guard ON application_drafts"
    drop_table :draft_answers
    drop_table :application_drafts
    execute "DROP FUNCTION IF EXISTS enforce_draft_answer()"
    execute "DROP FUNCTION IF EXISTS enforce_application_draft()"
  end
end
