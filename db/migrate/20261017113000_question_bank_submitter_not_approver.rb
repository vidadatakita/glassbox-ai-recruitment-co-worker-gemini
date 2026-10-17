# frozen_string_literal: true

# Maker is not the checker, by person (Vida, 17 Oct 2026): the person who SUBMITTED a question bank
# version may not approve it either, not only its creator. The SUPERADMIN is exempt from both person
# rules (Vida 10:43: "superadmin may create, submit and approve"); the role rule still applies.
# Re-creates enforce_question_bank_freeze(); everything else is unchanged. down restores the
# creator-only rule of 20261017110000 (no superadmin exemption).
class QuestionBankSubmitterNotApprover < ActiveRecord::Migration[8.1]
  def up
    execute function_sql(person_check: <<~SQL)
      IF approver_role <> 'superadmin' AND NEW.approved_by_id IN (NEW.created_by_id, NEW.submitted_by_id) THEN
        RAISE EXCEPTION 'question_banks: the person who created or submitted the bank cannot approve it' USING ERRCODE = 'restrict_violation';
      END IF;
    SQL
  end

  def down
    execute function_sql(person_check: <<~SQL)
      IF NEW.approved_by_id = NEW.created_by_id THEN
        RAISE EXCEPTION 'question_banks: the person who created the bank cannot approve it' USING ERRCODE = 'restrict_violation';
      END IF;
    SQL
  end

  private

  def function_sql(person_check:)
    <<~SQL
      CREATE OR REPLACE FUNCTION enforce_question_bank_freeze() RETURNS trigger LANGUAGE plpgsql AS $$
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
          #{person_check}
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
    SQL
  end
end
