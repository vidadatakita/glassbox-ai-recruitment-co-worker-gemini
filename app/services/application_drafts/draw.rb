module ApplicationDrafts
  # Which questions one applicant gets (Vida 17 Oct 2026: a random draw, so applicants do not all see
  # the same set). Per section, the bank's questions are grouped by the brief row they test
  # (activity or competency); the groups and the questions inside them are shuffled, and questions are
  # taken one group at a time, round-robin, so every activity or competency is covered before any is
  # tested twice (stratified: scores stay comparable across applicants). Technical first, then role.
  module Draw
    module_function

    def call(bank, random: Random.new(SecureRandom.random_number(2**62)))
      QuestionBank::SECTIONS.keys.flat_map do |section|
        groups = bank.questions_in(section).group_by { |q| q.activity_id || q.competency_id }.values
        queues = groups.map { |list| list.shuffle(random:) }.shuffle(random:)
        picked = []
        until picked.size >= bank.draw_for(section) || queues.all?(&:empty?)
          queues.each { |queue| picked << queue.shift if queue.any? && picked.size < bank.draw_for(section) }
        end
        picked.map(&:id)
      end
    end
  end
end
