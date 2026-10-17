# frozen_string_literal: true

# The first interview question is the same for every applicant of a vacancy: the AI writes it once from the
# vacancy (title, activities, requirements) and it is stored here. It holds no applicant data, so the
# applicant erasure leaves it. The follow-up questions stay dynamic (they follow each applicant's answers).
class CreateInterviewOpenings < ActiveRecord::Migration[8.1]
  def change
    create_table :interview_openings do |t|
      t.references :job, null: false, foreign_key: true, index: { unique: true }
      t.text :question, null: false
      t.datetime :created_at, null: false
    end
  end
end
