require "test_helper"

# AI_SCREENING_REVIEW=auto (owner's decision 2026-10-10, docs/decisions/0004): the AI screens each
# CV as it arrives; people decide on the result. A CV whose redacted text still shows personal
# data is held for a reviewer, exactly as in the release-first mode.
class Screening::AutoModeTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ScreeningFactory

  setup { @job = screening_job }

  def auto(&) = with_env({ "AI_SCREENING_REVIEW" => "auto" }, &)

  # GlassBox Team 2026-10-13: auto is the default again (the AI Builder Cup rule).
  test "a clean CV is screened as soon as it arrives: no release, no reviewer before the AI" do
    fake = FakeGemini.new
    participation = auto do
      with_ai(fake) do
        fake.push(gemini_message(criteria_for(@job)))
        p = apply_with_cv!(@job)
        perform_enqueued_jobs
        p
      end
    end

    assert_equal "done", participation.reload.screening_state
    assert_equal 1, fake.requests.size, "sent once, straight after the application"
    assert_nil AiRelease.latest_for(participation), "no stored release in the automatic mode"
    result = participation.screening_results.last
    assert_nil result.ai_release_id
    PROTECTED.each { |value| refute_includes fake.bodies.first, value, "#{value.inspect} reached the AI" }
  end

  test "unset AI_SCREENING_REVIEW means auto; required still waits for a reviewer and sends nothing" do
    with_env({ "AI_SCREENING_REVIEW" => nil }) { refute Screening::Config.review_before_ai?, "unset is auto" }

    fake = FakeGemini.new
    participation = with_env({ "AI_SCREENING_REVIEW" => "required" }) do
      with_ai(fake) do
        p = apply_with_cv!(@job)
        perform_enqueued_jobs
        p
      end
    end
    assert_empty fake.requests, "required: nothing reaches the AI before a reviewer releases it"
    assert_equal "awaiting_release", participation.reload.screening_state
  end

  test "a CV whose redacted text still shows personal data is held for a reviewer, never sent" do
    fake = FakeGemini.new
    # A birth date the redactor's patterns miss, inside an evidence section (as failure_policy_test).
    cv = FIXTURE_CV.sub("Mengelola stok", "Lhr. Bdg 01-02-1990\nMengelola stok")
    participation = auto do
      with_ai(fake) do
        p = apply_with_cv!(@job, cv_text: cv)
        perform_enqueued_jobs
        p
      end
    end

    assert_equal "awaiting_release", participation.reload.screening_state
    assert_empty fake.requests, "nothing reached the AI"
    assert AiRelease.latest_for(participation).residual?
  end

  test "the release-first mode is unchanged: the CV waits for a reviewer" do
    fake = FakeGemini.new
    participation = with_env({ "AI_SCREENING_REVIEW" => "required" }) do
      with_ai(fake) do
        p = apply_with_cv!(@job)
        perform_enqueued_jobs
        p
      end
    end
    assert_equal "awaiting_release", participation.reload.screening_state
    assert_empty fake.requests
  end

  private

  def with_env(values)
    before = values.keys.to_h { |k| [k, ENV[k]] }
    values.each { |k, v| ENV[k] = v }
    yield
  ensure
    before.each { |k, v| ENV[k] = v }
  end
end
