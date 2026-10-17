module ApplicationDrafts
  # Step 3 begins when the applicant presses "Start the test": the draw is made and the deadline fixed,
  # once (the trigger application_drafts_guard refuses any later change). Pressing it again, or
  # reloading, returns the same draw and the same deadline.
  module StartTest
    module_function

    def call(draft, now: Time.current, random: nil)
      draft.with_lock do
        next draft if draft.test_started? || draft.submitted?

        draw = random ? Draw.call(draft.question_bank, random:) : Draw.call(draft.question_bank)
        draft.update!(draw:, test_started_at: now, test_due_at: now + draft.time_limit_minutes.minutes)
      end
      draft
    end
  end
end
