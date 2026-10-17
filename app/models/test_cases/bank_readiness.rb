module TestCases
  # What a competency test bank needs before the HR Admin may submit it and the HR Manager may approve
  # it. Each problem is a sentence that says what is missing and how to fix it. The trigger
  # question_banks_freeze repeats the counts, the brief links and the anchors at approval.
  module BankReadiness
    module_function

    def problems(bank)
      questions = bank.questions.to_a
      list = []
      QuestionBank::SECTIONS.each do |section, label|
        count = questions.count { |q| q.section == section }
        minimum = bank.minimum_for(section)
        next if count >= minimum

        list << "#{label}: #{count} of at least #{minimum} questions (each applicant draws #{bank.draw_for(section)}, " \
                "and the bank holds at least twice that). Add #{minimum - count} more."
      end
      questions.reject(&:linked?).each do |q|
        list << "Question #{q.position} is not linked to a brief #{q.technical? ? 'activity' : 'competency'}; choose one."
      end
      questions.select { |q| q.written? && !q.anchors_complete? }.each do |q|
        list << "Question #{q.position} is a written answer without all three scoring anchors (1, 3 and 5); fill them in."
      end
      list + orphan_problems(bank, questions)
    end

    # A question whose brief activity or competency was removed later tests something the job no longer
    # asks for (the same rule as TestCases::Requirement#orphan_problems for the uploaded case).
    def orphan_problems(bank, questions)
      activity_ids = bank.job.activities.pluck(:id)
      competency_ids = bank.job.competencies.pluck(:id)
      questions.filter_map do |q|
        gone = q.technical? ? q.activity_id && !activity_ids.include?(q.activity_id) : q.competency_id && !competency_ids.include?(q.competency_id)
        "Question #{q.position} tests \"#{q.link_text}\", which is no longer in the brief; link it again or remove it." if gone
      end
    end
  end
end
