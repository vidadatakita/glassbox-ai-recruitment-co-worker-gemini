# frozen_string_literal: true

# Competency test scoring, slice C (Vida, 17 Oct 2026; FLOW §7 row "OPEN, to discuss later"):
#   - multiple choice is scored by the answer key at Submit (draft_answers.correct, slice B);
#   - each written answer gets an AI suggestion automatically after Submit: a rating 1-5 against the
#     question's anchors, with a quote from the answer and a reason (ai_* columns);
#   - the HR Manager confirms written answers for applicants at or above the vacancy average
#     (review_* columns); for applicants below the average the AI suggestion counts (Vida's decision,
#     recorded with its trade-off: the AI's rating then sets part of a score no person confirmed).
# The database repeats who may confirm: an HR Manager or the superadmin, never the vacancy's consultant
# (the same rule as the case-test score, enforce_test_score_author).
class AddScoringToDraftAnswers < ActiveRecord::Migration[8.1]
  def up
    change_table :draft_answers, bulk: true do |t|
      t.integer :ai_rating
      t.text :ai_quote
      t.text :ai_reason
      t.boolean :ai_quote_verified
      t.string :ai_model
      t.string :ai_prompt_version
      t.datetime :ai_rated_at
      t.integer :review_rating
      t.references :reviewed_by, foreign_key: { to_table: :users }
      t.datetime :reviewed_at
    end
    change_table :application_drafts, bulk: true do |t|
      # pending -> done | failed: the AI suggestions for this applicant's written answers.
      t.string :ai_status
      t.text :ai_error
    end
    execute <<~SQL
      ALTER TABLE draft_answers
        ADD CONSTRAINT draft_answers_ai_rating_range CHECK (ai_rating IS NULL OR ai_rating BETWEEN 1 AND 5),
        ADD CONSTRAINT draft_answers_review_rating_range CHECK (review_rating IS NULL OR review_rating BETWEEN 1 AND 5),
        ADD CONSTRAINT draft_answers_review_complete CHECK ((review_rating IS NULL) = (reviewed_by_id IS NULL) AND (reviewed_by_id IS NULL) = (reviewed_at IS NULL));
      ALTER TABLE application_drafts
        ADD CONSTRAINT application_drafts_ai_status CHECK (ai_status IS NULL OR ai_status IN ('pending', 'done', 'failed'));

      CREATE FUNCTION enforce_draft_answer_review() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE reviewer_role text; job_consultant bigint;
      BEGIN
        IF NEW.reviewed_by_id IS NULL OR NEW.reviewed_by_id IS NOT DISTINCT FROM OLD.reviewed_by_id AND NEW.review_rating IS NOT DISTINCT FROM OLD.review_rating THEN
          RETURN NEW;
        END IF;
        SELECT role INTO reviewer_role FROM users WHERE id = NEW.reviewed_by_id;
        SELECT jobs.consultant_id INTO job_consultant FROM application_drafts d JOIN jobs ON jobs.id = d.job_id
         WHERE d.id = NEW.application_draft_id;
        IF COALESCE(reviewer_role, '') NOT IN ('hr_manager', 'superadmin') OR (job_consultant IS NOT NULL AND job_consultant = NEW.reviewed_by_id) THEN
          RAISE EXCEPTION 'draft_answers: a written answer is confirmed by a reviewer who is not the job''s consultant'
            USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN NEW;
      END;
      $$;

      CREATE TRIGGER draft_answers_review_guard BEFORE UPDATE ON draft_answers
        FOR EACH ROW EXECUTE FUNCTION enforce_draft_answer_review();
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS draft_answers_review_guard ON draft_answers"
    execute "DROP FUNCTION IF EXISTS enforce_draft_answer_review()"
    execute "ALTER TABLE application_drafts DROP CONSTRAINT IF EXISTS application_drafts_ai_status"
    remove_column :application_drafts, :ai_status
    remove_column :application_drafts, :ai_error
    remove_reference :draft_answers, :reviewed_by, foreign_key: { to_table: :users }
    remove_columns :draft_answers, :ai_rating, :ai_quote, :ai_reason, :ai_quote_verified, :ai_model, :ai_prompt_version,
                   :ai_rated_at, :review_rating, :reviewed_at
  end
end
