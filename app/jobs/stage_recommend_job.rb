# AI Builder Cup step 07: refreshes the AI's recommendation for HR as soon as an invited
# interviewer's score arrives, so the interviewer's phone never waits on the AI. Ids only.
class StageRecommendJob < ApplicationJob
  queue_as :default

  def perform(participation_id, actor_id)
    return unless Screening::Config.enabled?

    Progression::Recommend.call(participation: Participation.find(participation_id), actor: User.find(actor_id))
  end
end
