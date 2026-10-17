module Progression
  # AI Builder Cup step 07: the HR PIC invites an interviewer without an account (the hiring
  # manager) to score an interview stage from a link. Returns [invite, raw token]; the token exists
  # only in this return value (the HR PIC copies or shares the link once).
  class InviteInterviewer
    class Refused < StandardError; end

    def self.call(**kwargs) = new(**kwargs).call

    def initialize(participation:, actor:, name:, now: Time.current)
      @participation = participation
      @actor = actor
      @name = name.to_s.strip
      @now = now
    end

    def call
      stage = @participation.stage
      raise Refused, "Sign in as staff to invite an assessor." unless Progression.inviter?(@actor)
      raise Refused, "This stage is not an interview." unless stage.score_source == "scorecard"
      raise Refused, "This stage is already closed." if stage.status == "closed"
      raise Refused, "The choice for this stage is already recorded." if @participation.progression_choice
      raise Refused, "Enter the assessor's name." if @name.empty?

      ActiveRecord::Base.transaction do
        invite = InterviewerInvite.create!(participation: @participation, interviewer_name: @name[0, 120], issued_by: @actor)
        _link, token = OneTimeLink.issue!(subject: invite, purpose: InterviewerInvite::LINK_PURPOSE,
                                          expires_at: @now + InterviewerInvite::LINK_DAYS.days)
        [invite, token]
      end
    end
  end
end
