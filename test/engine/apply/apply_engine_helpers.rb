# Shared fixtures for the independent test pass of the three-step application with the competency
# test (slice B, 17 Oct 2026). Every name, address and text is invented. Banks are built through
# TestCases::SaveBank / BankDecision and applicants walk the real ApplyController routes, so a fixture
# never holds a row the application could not have written.
module ApplyEngineHelpers
  include TechnicalTestFactory

  # A package-3 job with an approved uploaded case (technical_test_job) plus an approved bank.
  def three_step_job!(split: [10, 0])
    job = technical_test_job
    three_step_bank!(job, split:)
    job.reload
  end

  # A package-3 job whose ONLY test in force is the approved bank (no uploaded case): the slice-B rule.
  def bank_only_job!
    job = briefed_job(golongan: 3, package: 3, complete: false, test_case: false)
    three_step_bank!(job)
    result = Briefs::Complete.call(job:, actor: staff_user("hr_pic"))
    assert result.ok?, "complete refused: #{result.problems.map(&:message).inspect}"
    job.update_columns(ad_text: "Kami mencari staf gudang untuk tim di Bekasi.") if job.ad_text.blank?
    job.update!(ad_approved_at: Time.current, ad_approved_by_id: staff_user("hr_pic").id, consultant_id: staff_user("consultant").id)
    open_portal(job)
    Gates::Open.call(stage: job.stages.find_by!(code: "S1"))
    job.reload
  end

  # Exactly the minimum at the default draws (5 technical / 3 role): 10 technical questions split
  # over the brief's first and second activity as `split`, and 6 role questions (5 multiple choice,
  # 1 written). Correct answer is always option 0.
  def three_step_bank!(job, split: [10, 0])
    consultant = staff_user("consultant")
    job.update!(consultant_id: consultant.id) if job.consultant_id.nil?
    first, second = job.activities.first, job.activities.second
    competency = job.competencies.first
    save = ->(params) { assert TestCases::SaveBank.call(job:, actor: consultant, action: "add", params:).ok? }
    split[0].times { |i| save.call(section: "technical", kind: "multiple_choice", link_id: "a:#{first.id}", prompt: "Technical A#{i}", options: { "0" => "right", "1" => "wrong", "2" => "also wrong" }, correct: "0") }
    split[1].times { |i| save.call(section: "technical", kind: "multiple_choice", link_id: "a:#{second.id}", prompt: "Technical B#{i}", options: { "0" => "right", "1" => "wrong" }, correct: "0") }
    5.times { |i| save.call(section: "role", kind: "multiple_choice", link_id: "c:#{competency.id}", prompt: "Role #{i}", options: { "0" => "right", "1" => "wrong" }, correct: "0") }
    save.call(section: "role", kind: "written", link_id: "c:#{competency.id}", prompt: "Describe a hard day.", anchor_1: "a", anchor_3: "b", anchor_5: "c")
    bank = QuestionBank.latest_for(job)
    assert TestCases::BankDecision.call(bank:, actor: consultant, action: "submit").ok?
    bank.reload
    assert TestCases::BankDecision.call(bank:, actor: staff_user("reviewer"), action: "approve", seen_digest: bank.content_digest).ok?
    bank.reload
  end

  def three_step_details(job, knockout: "ya", email: "sari@contoh.example")
    get apply_start_path(job.public_code)
    token = Nokogiri::HTML(response.body).at("input[name='lamaran[consent_token]']")["value"]
    { lamaran: { name: "Sari Handayani", email:, phone: "081298765432", consent: "1", consent_token: token },
      knockout: job.knockout_questions.to_h { |q| [q.id.to_s, knockout] } }
  end

  def three_step_pdf = Rack::Test::UploadedFile.new(StringIO.new(PortalFactory::PDF_BYTES), "application/pdf", original_filename: "cv.pdf")

  # Step 1 through the routes. Returns [draft, secret].
  def three_step_open!(job, **kw)
    post apply_start_path(job.public_code), params: three_step_details(job, **kw)
    secret = response.location.to_s[%r{/d/([^/]+)/cv}, 1]
    assert secret, "step 1 did not open a draft: #{response.status}"
    [ApplicationDraft.find_by_secret(job, secret), secret]
  end

  # Steps 1, 2 and the start of 3. Returns [draft, secret].
  def three_step_started!(job, **kw)
    draft, secret = three_step_open!(job, **kw)
    post apply_cv_path(job.public_code, secret), params: { lamaran: { cv: three_step_pdf } }
    post apply_test_start_path(job.public_code, secret)
    [draft.reload, secret]
  end
end
