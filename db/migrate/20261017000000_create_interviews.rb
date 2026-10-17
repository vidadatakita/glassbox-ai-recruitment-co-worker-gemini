# frozen_string_literal: true

# AI interview before CV screening (docs/superpowers/specs/2026-10-16-ai-interview-design.md): one
# interview per application and up to five question/answer turns. The answer of a turn is written once
# (InterviewTurn); the texts are set to NULL only by CandidateErasure (consent withdrawn, retention).
class CreateInterviews < ActiveRecord::Migration[8.1]
  def change
    create_table :interviews do |t|
      t.references :job_application, null: false, foreign_key: true, index: { unique: true }
      t.string :status, null: false, default: "open"
      t.string :finish_reason
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end
    add_check_constraint :interviews, "status IN ('open', 'finished')", name: "interviews_status_known"
    add_check_constraint :interviews,
                         "finish_reason IS NULL OR finish_reason IN ('completed', 'ended_by_candidate', 'time_up', 'never_started', " \
                         "'ai_unavailable', 'consent_withdrawn', 'staff_started')", name: "interviews_finish_reason_known"

    create_table :interview_turns do |t|
      t.references :interview, null: false, foreign_key: true
      t.integer :position, null: false
      t.text :question
      t.text :answer_raw
      t.text :answer_clean
      t.boolean :held, null: false, default: false
      t.datetime :asked_at, null: false
      t.datetime :answered_at
      t.timestamps
    end
    add_index :interview_turns, %i[interview_id position], unique: true
    add_check_constraint :interview_turns, "position BETWEEN 1 AND 5", name: "interview_turns_position_range"

    # Why and when the texts of one interview were erased (consent withdrawn, retention end). Written first by
    # CandidateErasure; append-only (AppendOnly). actor NULL = the system or the candidate's own withdrawal.
    create_table :interview_erasures do |t|
      t.references :interview, null: false, foreign_key: true
      t.references :actor, foreign_key: { to_table: :users }
      t.string :reason, null: false
      t.text :note
      t.datetime :created_at, null: false
    end
    add_check_constraint :interview_erasures, "reason IN ('retention_expired', 'consent_withdrawn', 'no_consent')", name: "interview_erasures_reason_known"
  end
end
