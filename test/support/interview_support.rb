# The AI interview retries a busy AI after a short pause; tests do not wait.
class ActiveSupport::TestCase
  setup { Interviews::Next.pauses = [0, 0] }

  # The AI interview runs only under a consent text that names it (ConsentTemplate#names_ai_interview?,
  # 18 Oct 2026). Interview tests publish such a version first: the in-force text with the demo
  # addendum, effective a second ago so it is the one in force. Every other test keeps a consent text
  # that does NOT name the interview, so the guard stays meaningful across the suite.
  def consent_naming_ai_interview!(company: nil)
    base = ConsentTemplate.in_force(company:)
    return base if base&.names_ai_interview?

    attrs = if base then base.with_ai_interview_addendum
            else ConsentTemplate::SECTIONS.keys.to_h { |f| [f, ["Test text for #{f}.", ConsentTemplate::AI_INTERVIEW_ADDENDUM[f]].compact.join(" ")] }
            end
    ConsentTemplate.create!(attrs.merge(version: "ai-interview-#{SecureRandom.hex(3)}", effective_from: 1.second.ago, created_at: Time.current))
  end

  def switch_ai_interview_on(actor: staff_user("admin"))
    consent_naming_ai_interview!
    Portal::UpdateSetting.call(key: "ai_interview", value: "1", actor:)
  end
end
