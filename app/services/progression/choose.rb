module Progression
  # AI Builder Cup step 06: the HR PIC's choice, Lanjut / Rekomendasi AI / Tidak Lanjut, for one step
  # (a stage, or the S1+S2 gate on its S1 row). The choice, not the AI or the threshold, moves the
  # candidate (D63 plan, option C1 a):
  #   - the stage's own decision stays the scoring record; where the choice disagrees with it (or
  #     there is none yet), a manual Decision with the choice's note is written, so the two never
  #     contradict each other;
  #   - Lanjut adds the candidate to the job's next stage.
  # Refused: anyone but the HR PIC (the database too), a second choice, "Rekomendasi AI" without a
  # ready recommendation, a recommendation newer than the one on screen (stale), and a missing note
  # on every Tidak Lanjut or on any choice that departs from the AI's advice.
  class Choose
    class Refused < StandardError
      attr_reader :field

      def initialize(message, field: nil)
        super(message)
        @field = field
      end
    end

    def self.call(**kwargs) = new(**kwargs).call

    def initialize(participation:, actor:, choice:, seen_recommendation_id:, note: nil, now: Time.current)
      @participation = participation
      @actor = actor
      @choice = choice.to_s
      @seen = seen_recommendation_id.presence&.to_i
      # A note of invisible characters only is treated as no note (Progression.blank_note?).
      @note = Progression.blank_note?(note) ? "" : note.to_s.strip
      @now = now
    end

    def call
      refuse!("Only the HR owner chooses Continue or Do not continue.") unless @actor&.role == CHOOSER
      refuse!("The choice for this stage is recorded on CV screening.") unless Progression.step?(@participation)
      refuse!("The choice for this stage is already recorded.") if @participation.progression_choice
      refuse!("Unknown choice.") unless ProgressionChoice::CHOICES.key?(@choice)
      refuse!("This stage is already closed.") if @participation.stage.status == "closed"

      latest = StageRecommendation.latest_for(@participation)
      if latest && latest.id != @seen
        refuse!("The AI advice has been refreshed. Read it again before choosing.")
      end
      advice = latest&.ready? ? latest.advice : nil
      if @choice == "ikut_ai" && !advice
        refuse!("No AI advice is available yet. Choose Continue or Do not continue yourself.")
      end

      direction = @choice == "ikut_ai" ? advice : @choice
      if @note.empty? && direction == "tidak_lanjut"
        refuse!("A reason is required for every Do not continue.", field: :note)
      elsif @note.empty? && advice && direction != advice
        refuse!("Your choice departs from the AI advice. Write the reason.", field: :note)
      end

      ActiveRecord::Base.transaction do
        Progression.open_stage!(@participation.stage, @now)
        align_decisions!(direction)
        choice = ProgressionChoice.create!(participation: @participation, stage_recommendation: (latest if @choice == "ikut_ai" || advice),
                                           choice: @choice, direction:, note: @note.presence, actor: @actor, created_at: @now)
        enter_next_stage! if direction == "lanjut"
        choice
      end
    end

    private

    # A manual Decision on every member of the step whose current decision says otherwise.
    def align_decisions!(direction)
      outcome = direction == "lanjut" ? "pass" : "eliminate"
      note = @note.presence || "#{ProgressionChoice::CHOICES.fetch(@choice)} chosen by #{@actor.name}."
      Progression.step_members(@participation).each do |member|
        current = member.current_decision
        next if current&.outcome == outcome

        Decision.create!(participation: member, outcome:, basis: "manual", reason_code: "progression_choice", note:,
                         decided_by_id: @actor.id, decided_at: @now, supersedes: current)
      end
    end

    def enter_next_stage!
      stage = Progression.next_stage(@participation)
      return unless stage

      Participation.find_or_create_by!(job_application: @participation.job_application, stage:) { |p| p.attendance = "pending" }
    end

    def refuse!(message, field: nil) = raise(Refused.new(message, field:))
  end
end
