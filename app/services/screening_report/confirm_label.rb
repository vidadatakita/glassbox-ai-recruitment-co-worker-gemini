module ScreeningReport
  # The reviewer confirms the Analisa label of one candidate's CURRENT S1 result (D61 "a person
  # confirms every label"; D62 h3, h4). Rules, each also held by the database where it can be:
  #   - role reviewer, never the job's consultant (feature-06 rule; trigger enforce_screening_reviewer)
  #   - the label is one of the six; a note is required when the reviewer departs from the AI's
  #     proposal (builder default: an override is never unexplained, rule 4 spirit)
  #   - Over-qualified ONLY when the reviewer sets the last role's Golongan at least two above the
  #     job's, the last-position quote was found in the CV, and a note is given (D62 h3). Years of
  #     experience or age are never an input: the service has no such parameter.
  # The label is advisory: this writes no Decision (h4; the 30% gate decides).
  class ConfirmLabel
    class Refused < StandardError; end

    def self.call(**) = new(**).call

    def initialize(participation:, reviewer:, label:, note: nil, last_role_golongan: nil)
      @participation = participation
      @reviewer = reviewer
      @label = label.to_s
      @note = note.to_s.strip.presence
      @last_role_golongan = last_role_golongan.presence && Integer(last_role_golongan, exception: false)
      @job = Job.find(participation.stage.job_id) # fresh: the consultant rule must read the current row
    end

    def call
      check!
      ScreeningLabelConfirmation.create!(
        participation: @participation, screening_result: result, reviewer: @reviewer, label: @label,
        last_role_golongan: @last_role_golongan, job_golongan: @job.golongan, note: @note, created_at: Time.current
      )
    end

    private

    def result = @result ||= ScreeningResult.current_for(@participation.id).first

    def check!
      refuse("Only a reviewer confirms the label.") unless @reviewer.role == "reviewer"
      refuse("The consultant of this vacancy cannot confirm the label.") if @job.consultant_id == @reviewer.id
      refuse("No AI CV screening result for this candidate yet.") if result.nil?
      refuse("Choose one label.") unless Labels::ALL.key?(@label)
      check_over_qualified! if @label == "over_qualified"
      refuse("Write a note: the label differs from the AI advice.") if @note.nil? && @label != result.label_proposal
    end

    def check_over_qualified!
      refuse("Over-qualified requires a note.") if @note.nil?
      refuse("Over-qualified only when the Grade of the last position is given.") if @last_role_golongan.nil?
      unless Labels.over_qualified_allowed?(last_role_golongan: @last_role_golongan, job_golongan: @job.golongan)
        refuse("Over-qualified only when the last position is at least 2 Grades above the vacancy (G#{@job.golongan}).")
      end
      return if result.last_position.is_a?(Hash) && result.last_position["verified"]

      refuse("Over-qualified only when the last position is supported by a quote found in the CV.")
    end

    def refuse(message) = raise(Refused, message)
  end
end
