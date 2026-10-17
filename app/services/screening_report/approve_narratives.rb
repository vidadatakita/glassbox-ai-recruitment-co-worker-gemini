module ScreeningReport
  # The consultant approves the four AI narrative boxes of one S1 result (D62 h2): "Draf AI" until
  # then. The job's assigned consultant when there is one, else any consultant (same rule as the
  # test-case authority, feature 07); the trigger enforce_narrative_approver holds it too. One
  # approval per result: a re-screening produces a new result that needs its own approval.
  class ApproveNarratives
    class Refused < StandardError; end

    def self.call(**) = new(**).call

    def initialize(result:, user:, note: nil)
      @result = result
      @user = user
      @note = note.to_s.strip.presence
      @job = Job.find(result.participation.stage.job_id) # fresh: the consultant rule reads the current row
    end

    def call
      refuse("Only a consultant approves the narrative.") unless @user.role.in?(%w[hr_admin superadmin])
      refuse("Only the consultant of this vacancy approves the narrative.") if @job.consultant_id && @job.consultant_id != @user.id
      refuse("This result has no AI narrative.") if @result.narratives.blank?
      refuse("The narrative of this result is already approved.") if ScreeningNarrativeApproval.exists?(screening_result_id: @result.id)
      refuse("There is a newer CV screening result; approve the latest narrative.") unless current?

      ScreeningNarrativeApproval.create!(screening_result: @result, approved_by: @user, note: @note, created_at: Time.current)
    end

    private

    def current? = ScreeningResult.current_for(@result.participation_id).pick(:id) == @result.id
    def refuse(message) = raise(Refused, message)
  end
end
