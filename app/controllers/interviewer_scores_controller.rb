# AI Builder Cup step 07: the page an invited interviewer (the hiring manager, no account) opens
# from the link on a phone. Blind: the candidate is "Kandidat NN", and no other interviewer's score,
# no stage score and no AI advice is shown. One submission per link.
class InterviewerScoresController < CandidateController
  rate_limit to: 10, within: 10.minutes, only: :create, by: -> { OneTimeLink.digest(params[:token]) }
  before_action :load_invite

  def show
    return render(:done) if @invite.submitted?
  end

  def create
    Progression::SubmitInterviewerScore.call(link: @link, ratings: params[:ratings]&.to_unsafe_h || {}, note: params[:note], pick: params[:pick])
    render :done
  rescue Progression::SubmitInterviewerScore::Refused => e
    @error = e.message
    render :show, status: :unprocessable_entity
  end

  private

  def load_invite
    @link = OneTimeLink.live(InterviewerInvite::LINK_PURPOSE, params[:token])
    return render_invalid_link unless @link

    @invite = @link.subject
    @participation = @invite.participation
    @job = @participation.stage.job
    @competencies = @job.competencies.where(stage_code: @participation.stage.code)
  end
end
