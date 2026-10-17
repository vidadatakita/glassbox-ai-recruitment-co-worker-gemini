# frozen_string_literal: true

# Competency test bank (GlassBox Team, 17 Oct 2026; FLOW §7 "Competency test moves into job
# preparation"). Built BESIDE the uploaded case file (test_cases), which stays as it is.
#
# A vacancy's bank is versioned like test_cases, in three steps (Vida, 17 Oct 2026): the HR Admin
# builds the draft; the HR Admin confirms the work is done ("Submit for approval", submitted_at), which
# locks the questions; the HR Manager approves it (maker is not the checker) or returns it to draft
# with a reason. Approval without a submission is refused. An approved version is final and a change
# is a new version with a reason. Two sections: "technical" (each question tests one brief activity) and "role"
# (each question tests one brief competency). Each applicant later draws technical_draw + role_draw
# questions (slice B); the bank must hold at least TWICE the draw per section, so no applicant sees
# more than half of a section (the 10 -> 5 and 6 -> 3 defaults Vida chose).
#
# The database repeats the rules that must survive a bug in the app: drafts only at insert, never
# deleted, locked while submitted, frozen once approved, the approver is an HR Manager or the superadmin and never the bank's
# creator, and the bank is complete at the moment of approval.
class CreateQuestionBanks < ActiveRecord::Migration[8.1]
  def up
    create_table :question_banks do |t|
      t.references :job, null: false, foreign_key: true
      t.integer :version, null: false
      t.integer :technical_draw, null: false, default: 5
      t.integer :role_draw, null: false, default: 3
      # Minutes for the whole test in the application form (slice B timer). Default 30, at most 60,
      # the same ceiling as the uploaded case (TechnicalTestCase::MAX_TIME_LIMIT).
      t.integer :time_limit_minutes, null: false, default: 30
      t.text :new_version_reason
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.references :submitted_by, foreign_key: { to_table: :users }
      t.datetime :submitted_at
      t.references :approved_by, foreign_key: { to_table: :users }
      t.datetime :approved_at
      t.timestamps
    end
    add_index :question_banks, %i[job_id version], unique: true
    execute <<~SQL
      ALTER TABLE question_banks
        ADD CONSTRAINT question_banks_version_positive CHECK (version >= 1),
        ADD CONSTRAINT question_banks_draws_range CHECK (technical_draw BETWEEN 1 AND 20 AND role_draw BETWEEN 1 AND 20),
        ADD CONSTRAINT question_banks_time_limit_range CHECK (time_limit_minutes BETWEEN 1 AND 60),
        ADD CONSTRAINT question_banks_approval_pair CHECK ((approved_at IS NULL) = (approved_by_id IS NULL)),
        ADD CONSTRAINT question_banks_submission_pair CHECK ((submitted_at IS NULL) = (submitted_by_id IS NULL)),
        ADD CONSTRAINT question_banks_approved_was_submitted CHECK (approved_at IS NULL OR submitted_at IS NOT NULL),
        ADD CONSTRAINT question_banks_new_version_has_reason CHECK (version = 1 OR length(btrim(COALESCE(new_version_reason, ''))) > 0)
    SQL

    create_table :bank_questions do |t|
      t.references :question_bank, null: false, foreign_key: true
      t.string :section, null: false
      t.string :kind, null: false
      t.integer :position, null: false
      # The brief row the question tests, by id plus a snapshot of its text: an activity or
      # competency edited or removed later must not change what an approved question tested (the
      # same choice as test_case_criteria.activity_text). No foreign key on purpose: brief rows are
      # rewritten by Briefs::SaveStep and an approved bank must never block that save.
      t.bigint :activity_id
      t.text :activity_text
      t.bigint :competency_id
      t.string :competency_name
      t.text :prompt, null: false
      # Multiple choice: 2 to 6 options, correct_index is 0-based. Written: no options; anchors
      # 1/3/5 say what a weak, adequate and excellent answer observably contains.
      t.text :options, array: true, null: false, default: []
      t.integer :correct_index
      t.text :anchor_1
      t.text :anchor_3
      t.text :anchor_5
      t.string :source, null: false, default: "manual"
      t.timestamps
    end
    add_index :bank_questions, %i[question_bank_id position], unique: true
    execute <<~SQL
      ALTER TABLE bank_questions
        ADD CONSTRAINT bank_questions_section CHECK (section IN ('technical', 'role')),
        ADD CONSTRAINT bank_questions_kind CHECK (kind IN ('multiple_choice', 'written')),
        ADD CONSTRAINT bank_questions_source CHECK (source IN ('manual', 'ai', 'import')),
        ADD CONSTRAINT bank_questions_position_positive CHECK (position >= 1),
        ADD CONSTRAINT bank_questions_prompt_present CHECK (length(btrim(prompt)) > 0),
        ADD CONSTRAINT bank_questions_link_matches_section CHECK (
          (section = 'technical' AND competency_id IS NULL) OR (section = 'role' AND activity_id IS NULL)),
        ADD CONSTRAINT bank_questions_shape CHECK (
          (kind = 'multiple_choice' AND cardinality(options) BETWEEN 2 AND 6
             AND correct_index IS NOT NULL AND correct_index >= 0 AND correct_index < cardinality(options))
          OR (kind = 'written' AND cardinality(options) = 0 AND correct_index IS NULL))
    SQL

    execute <<~SQL
      CREATE FUNCTION enforce_question_bank_inserted_as_draft() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.approved_at IS NOT NULL OR NEW.approved_by_id IS NOT NULL OR NEW.submitted_at IS NOT NULL THEN
          RAISE EXCEPTION 'question_banks: a version is inserted as a draft; the HR Admin submits it and the HR Manager approves it'
            USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN NEW;
      END;
      $$;

      CREATE TRIGGER question_banks_inserted_as_draft BEFORE INSERT ON question_banks
        FOR EACH ROW EXECUTE FUNCTION enforce_question_bank_inserted_as_draft();

      CREATE FUNCTION enforce_question_bank_freeze() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE approver_role varchar; technical_count integer; role_count integer; incomplete integer;
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'question_banks: a version is never deleted' USING ERRCODE = 'restrict_violation';
        END IF;
        IF OLD.approved_at IS NOT NULL THEN
          RAISE EXCEPTION 'question_banks: version % is approved and final; make a new version', OLD.version
            USING ERRCODE = 'restrict_violation';
        END IF;
        IF NEW.job_id <> OLD.job_id OR NEW.version <> OLD.version OR NEW.created_by_id <> OLD.created_by_id THEN
          RAISE EXCEPTION 'question_banks: job, version and creator never change' USING ERRCODE = 'restrict_violation';
        END IF;
        IF OLD.submitted_at IS NOT NULL AND NEW.submitted_at IS NOT NULL
           AND (NEW.technical_draw <> OLD.technical_draw OR NEW.role_draw <> OLD.role_draw
                OR NEW.time_limit_minutes <> OLD.time_limit_minutes) THEN
          RAISE EXCEPTION 'question_banks: version % is submitted for approval; return it to draft before changing it', OLD.version
            USING ERRCODE = 'restrict_violation';
        END IF;
        IF NEW.approved_at IS NOT NULL THEN
          SELECT role INTO approver_role FROM users WHERE id = NEW.approved_by_id;
          -- NULL-safe on purpose: a missing user must not pass a NOT IN.
          IF COALESCE(approver_role, '') NOT IN ('hr_manager', 'superadmin') THEN
            RAISE EXCEPTION 'question_banks: only the HR Manager approves a question bank' USING ERRCODE = 'restrict_violation';
          END IF;
          IF NEW.approved_by_id = NEW.created_by_id THEN
            RAISE EXCEPTION 'question_banks: the person who created the bank cannot approve it' USING ERRCODE = 'restrict_violation';
          END IF;
          SELECT count(*) FILTER (WHERE section = 'technical'), count(*) FILTER (WHERE section = 'role'),
                 count(*) FILTER (WHERE (section = 'technical' AND activity_id IS NULL)
                                     OR (section = 'role' AND competency_id IS NULL)
                                     OR (kind = 'written' AND (length(btrim(COALESCE(anchor_1, ''))) = 0
                                                               OR length(btrim(COALESCE(anchor_3, ''))) = 0
                                                               OR length(btrim(COALESCE(anchor_5, ''))) = 0)))
            INTO technical_count, role_count, incomplete
            FROM bank_questions WHERE question_bank_id = NEW.id;
          IF technical_count < 2 * NEW.technical_draw OR role_count < 2 * NEW.role_draw THEN
            RAISE EXCEPTION 'question_banks: the bank needs at least twice the draw per section (technical %/% , role %/%)',
              technical_count, 2 * NEW.technical_draw, role_count, 2 * NEW.role_draw USING ERRCODE = 'restrict_violation';
          END IF;
          IF incomplete > 0 THEN
            RAISE EXCEPTION 'question_banks: % question(s) lack their brief link or scoring anchors', incomplete
              USING ERRCODE = 'restrict_violation';
          END IF;
        END IF;
        RETURN NEW;
      END;
      $$;

      CREATE TRIGGER question_banks_freeze BEFORE UPDATE OR DELETE ON question_banks
        FOR EACH ROW EXECUTE FUNCTION enforce_question_bank_freeze();

      CREATE FUNCTION enforce_bank_question_freeze() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE bank_id bigint;
      BEGIN
        bank_id := CASE WHEN TG_OP = 'INSERT' THEN NEW.question_bank_id ELSE OLD.question_bank_id END;
        IF EXISTS (SELECT 1 FROM question_banks b WHERE b.id = bank_id AND b.approved_at IS NOT NULL) THEN
          RAISE EXCEPTION 'bank_questions: the bank is approved and final; make a new version' USING ERRCODE = 'restrict_violation';
        END IF;
        IF EXISTS (SELECT 1 FROM question_banks b WHERE b.id = bank_id AND b.submitted_at IS NOT NULL) THEN
          RAISE EXCEPTION 'bank_questions: the bank is submitted for approval; return it to draft before any change'
            USING ERRCODE = 'restrict_violation';
        END IF;
        IF TG_OP = 'UPDATE' AND NEW.question_bank_id <> OLD.question_bank_id THEN
          RAISE EXCEPTION 'bank_questions: a question never moves to another bank' USING ERRCODE = 'restrict_violation';
        END IF;
        IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
        RETURN NEW;
      END;
      $$;

      CREATE TRIGGER bank_questions_freeze BEFORE INSERT OR UPDATE OR DELETE ON bank_questions
        FOR EACH ROW EXECUTE FUNCTION enforce_bank_question_freeze();
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS bank_questions_freeze ON bank_questions"
    execute "DROP TRIGGER IF EXISTS question_banks_freeze ON question_banks"
    execute "DROP TRIGGER IF EXISTS question_banks_inserted_as_draft ON question_banks"
    drop_table :bank_questions
    drop_table :question_banks
    execute "DROP FUNCTION IF EXISTS enforce_bank_question_freeze()"
    execute "DROP FUNCTION IF EXISTS enforce_question_bank_freeze()"
    execute "DROP FUNCTION IF EXISTS enforce_question_bank_inserted_as_draft()"
  end
end
