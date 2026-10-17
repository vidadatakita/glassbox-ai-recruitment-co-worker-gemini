require "test_helper"

# AI Builder Cup step 09: the AI drafts the rejection or offer letter with placeholders; the HR PIC
# sends it; the name is filled only in the email; what was sent stays on record.
class LettersTest < ActiveSupport::TestCase
  include TechnicalTestFactory
  include ActionMailer::TestHelper

  Fake = Struct.new(:text, :seen) do
    def generate(system:, schema:, content:)
      self.seen = content
      Screening::AiClient::Reply.new(model: "uji-model", text:, input_tokens: 1, output_tokens: 1)
    end
  end

  setup do
    @job = technical_test_job(open_gate: false)
    @job.update_columns(salary_min: 5_200_000, salary_max: 6_000_000)
    @application, = applicant!(@job, name: "Dewi Lestari")
    @hr = staff_user("hr_pic")
    @s1 = s1_of(@application)
  end

  def draft_with(subject, body)
    fake = Fake.new({ subject:, body: }.to_json)
    letter = Screening::Config.stub(:enabled?, true) do
      Screening::Config.stub(:client, fake) { Progression::Letters.draft(application: @application, actor: @hr) }
    end
    [letter, fake.seen]
  end

  test "no letter before a decision; a rejection after Tidak Lanjut, sent with the name filled in and kept on record" do
    assert_nil Progression::Letters.kind_for(@application)
    Progression::Choose.call(participation: @s1, actor: @hr, choice: "tidak_lanjut", seen_recommendation_id: nil, note: "Belum sesuai.")
    assert_equal "rejection", Progression::Letters.kind_for(@application)

    letter, sent = draft_with("About your application", "Dear [Candidate name],\nThank you for applying.\nHR Team")
    ["Dewi", "Lestari", @application.candidate.email, "Belum sesuai"].each { |v| refute_includes sent, v }
    assert_includes sent, "CV screening"
    assert_equal "Dear Dewi,\nThank you for applying.\nHR Team", letter.body,
                 "decided at the gate, so the HR PIC may see the name: the app fills it into the draft"

    assert_emails 1 do
      Progression::Letters.send!(application: @application, actor: @hr, subject: letter.subject, body: letter.body)
    end
    mail = ActionMailer::Base.deliveries.last
    assert_includes mail.body.to_s, "Dear Dewi,"
    record = CandidateLetter.latest(@application, "rejection", "sent")
    assert_equal letter.body, record.body, "the text as the HR PIC approved it"
    assert record.mail_delivery.sent?
    assert_raises(ActiveRecord::ReadOnlyRecord) { record.update!(body: "lain") }
  end

  test "line breaks the model escaped become real ones; the recruiter's tone is followed" do
    assert_equal "Halo,\n\nSelamat.", Progression::Letters.plain("Halo,\\n\\nSelamat.  ")
    assert_includes Progression::Letters::SYSTEM, "follow it fully, whatever register it asks for"
  end

  test "a style rewrite never loses a placeholder: markers go to the AI, a mangled answer keeps the plain draft" do
    draft = { "subject" => "News", "body" => "Hello [Candidate name],\nStart on [Start date]." }
    good = Fake.new({ subject: "News!", body: "Hi §1§, you start on §2§.", word_limit: 0 }.to_json)
    out = Screening::Config.stub(:client, good) { Progression::Letters.restyle(draft, "santai") }
    assert_equal "Hi [Candidate name], you start on [Start date].", out["body"]
    refute_includes good.seen, "[Candidate name]", "the AI saw markers, not the placeholders"

    mangled = Fake.new({ subject: "News", body: "Hiya §1§, starting.", word_limit: 0 }.to_json)
    assert_nil Screening::Config.stub(:client, mangled) { Progression::Letters.restyle(draft, "gaya lain") }
  end

  test "a word limit is counted by the code: too long, the AI is asked once more with the exact numbers" do
    draft = { "subject" => "News", "body" => "Hello [Candidate name], congratulations." }
    answers = [{ subject: "News", body: "Hello §1§, congratulations, you have been accepted for this position and we are very happy.", word_limit: 5 },
               { subject: "News", body: "Hello §1§, you are accepted.", word_limit: 5 }]
    client = Struct.new(:answers, :systems) do
      def generate(system:, schema:, content:)
        (self.systems ||= []) << system
        Screening::AiClient::Reply.new(model: "uji", text: answers.shift.to_json, input_tokens: 1, output_tokens: 1)
      end
    end.new(answers)
    out = Screening::Config.stub(:client, client) { Progression::Letters.restyle(draft, "at most 5 words") }
    assert_equal "Hello [Candidate name], you are accepted.", out["body"]
    assert_match(/has 15 words; the instruction allows at most 5/, client.systems.last)
  end

  test "a viewer who may not see the name yet keeps the placeholder in the draft; the email still gets the name" do
    Progression::Choose.call(participation: @s1, actor: @hr, choice: "tidak_lanjut", seen_recommendation_id: nil, note: "Belum sesuai.")
    CandidateIdentity.stub(:visible_to?, false) do
      letter, = draft_with("News", "Dear [Candidate name],\nThank you.")
      assert_equal "Dear [Candidate name],\nThank you.", letter.body
      assert_emails(1) { Progression::Letters.send!(application: @application, actor: @hr, subject: "News", body: letter.body) }
      assert_includes ActionMailer::Base.deliveries.last.body.to_s, "Dear Dewi,"
    end
  end

  test "the offer: the code fills the agreed salary; unfilled placeholders and the HR Manager are refused" do
    Screening::Config.stub(:enabled?, false) do
      Progression::Choose.call(participation: @s1, actor: @hr, choice: "lanjut", seen_recommendation_id: nil)
      s3 = @application.participations.joins(:stage).find_by!(stages: { code: "S3" })
      Progression::ScoreInterview.call(participation: s3, actor: @hr, attendance: "attended",
                                       ratings: @job.competencies.where(stage_code: "S3").to_h { |c| [c.id.to_s, "4"] })
      Progression::Choose.call(participation: s3, actor: @hr, choice: "lanjut", seen_recommendation_id: StageRecommendation.latest_for(s3)&.id)
      s5 = @application.participations.joins(:stage).find_by!(stages: { code: "S5" })
      Progression::Choose.call(participation: s5, actor: @hr, choice: "lanjut", seen_recommendation_id: nil)
    end
    SalaryAgreement.create!(job_application: @application, agreed_amount: 5_750_000, outside_band: false, decided_by: staff_user("owner"), created_at: Time.current)
    assert_equal "offer", Progression::Letters.kind_for(@application)

    letter, sent = draft_with("Job offer", "Hello [Candidate name], salary [Salary] per month, starting [Start date].")
    refute_match(/5[.,]?750/, sent, "the AI never sees the salary")
    assert_includes letter.body, "Rp5.750.000 per month"

    error = assert_raises(Progression::Letters::Refused) do
      Progression::Letters.send!(application: @application, actor: @hr, subject: letter.subject, body: letter.body)
    end
    assert_match(/\[Start date\]/, error.message)
    assert_raises(Progression::Letters::Refused) do
      Progression::Letters.send!(application: @application, actor: staff_user("reviewer"), subject: "x", body: "y")
    end
  end
end
