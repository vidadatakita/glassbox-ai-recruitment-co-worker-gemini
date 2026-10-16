# "Tanya Data": what the read function returned (labels, counts, statuses; never names), kept with
# the question. The chat history rebuilds the applicant table and links from it after a reload, and
# the audit shows exactly what the AI read.
class AddDataToDataQuestions < ActiveRecord::Migration[8.1]
  def change
    add_column :data_questions, :data, :jsonb
  end
end
