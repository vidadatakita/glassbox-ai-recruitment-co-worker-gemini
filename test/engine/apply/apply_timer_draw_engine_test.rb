require "test_helper"
require_relative "apply_engine_helpers"

# Independent test pass, three-step application slice B: the timer (deadline + grace, kept by the
# service AND the trigger), the draw (stratified per activity, random per applicant, fixed at start,
# pinned to the bank version the applicant started on) and what an answer may be. Each test names
# the boundary it sits on; every refusal has a control that is accepted.
class ApplyTimerDrawEngineTest < ActionDispatch::IntegrationTest
  include ApplyEngineHelpers

  T0 = Time.zone.parse("2026-10-20 09:00:00")

  setup { travel_to T0 }

  def saved(draft, raw, now:) = ApplicationDrafts::SaveAnswers.call(draft.reload, raw, now:)

  test "an answer is accepted up to the deadline plus the grace, to the second, and refused one second later" do
    job = three_step_job!
    draft, = three_step_started!(job)
    q = draft.questions.first
    due = draft.test_due_at
    assert_equal T0 + 30.minutes, due, "the bank's default limit is 30 minutes, fixed at start"
    assert_equal 120, draft.grace_seconds

    assert_equal 1, saved(draft, { q.id => "1" }, now: due).saved, "at the deadline"
    assert_equal 1, saved(draft, { q.id => "2" }, now: due + 119.seconds).saved, "at deadline + grace - 1 s"
    assert_equal 1, saved(draft, { q.id => "0" }, now: due + 120.seconds).saved, "at deadline + grace exactly (the rule is '>')"
    late = saved(draft, { q.id => "1" }, now: due + 121.seconds)
    assert_equal 0, late.saved
    assert_match(/time for the test is over/, late.error)
    assert_equal 0, draft.answers.find_by!(bank_question: q).choice_index, "the late answer did not overwrite the last saved one"
  end

  test "the trigger refuses a late answer even when the service is bypassed; the same row at the boundary is accepted" do
    job = three_step_job!
    draft, = three_step_started!(job)
    q1, q2 = draft.questions.first(2)
    limit = draft.test_due_at + draft.grace_seconds.seconds
    DraftAnswer.create!(application_draft: draft, bank_question: q1, choice_index: 0, saved_at: limit) # control
    refused_by_database { DraftAnswer.create!(application_draft: draft, bank_question: q2, choice_index: 0, saved_at: limit + 1.second) }
    refused_by_database { DraftAnswer.find_by!(bank_question: q1, application_draft: draft).update!(choice_index: 1, saved_at: limit + 1.second) }
  end

  test "only drawn questions: another bank's question and an undrawn question are skipped by the service and refused by the trigger" do
    job = three_step_job!
    draft, = three_step_started!(job)
    other_job = three_step_job!
    foreign = QuestionBank.current_for(other_job).questions.first
    undrawn = draft.question_bank.questions.where.not(id: draft.draw).first
    assert undrawn, "the bank holds twice the draw, so some question is not drawn"
    drawn = draft.questions.first

    result = saved(draft, { foreign.id => "0", undrawn.id => "0", drawn.id => "0" }, now: T0 + 1.minute)
    assert_equal 1, result.saved, "control: the drawn question in the same request is saved"
    assert_equal [drawn.id], draft.answers.pluck(:bank_question_id)

    refused_by_database { DraftAnswer.create!(application_draft: draft, bank_question: undrawn, choice_index: 0, saved_at: T0) }
    refused_by_database { DraftAnswer.create!(application_draft: draft, bank_question: foreign, choice_index: 0, saved_at: T0) }
  end

  test "a choice index out of range, negative, non-numeric or fractional stores nothing; a written answer is cut at 4000 characters" do
    job = three_step_job!
    draft, secret = three_step_open!(job)
    post apply_cv_path(job.public_code, secret), params: { lamaran: { cv: three_step_pdf } }
    bank = draft.question_bank
    written_id = bank.questions.find(&:written?).id
    seed = (1..200).find { |s| ApplicationDrafts::Draw.call(bank, random: Random.new(s)).include?(written_id) }
    ApplicationDrafts::StartTest.call(draft.reload, random: Random.new(seed)) # a draw that holds the written question
    draft.reload
    mc = draft.questions.select(&:multiple_choice?)
    written = draft.questions.find(&:written?)
    three = mc.find { |q| q.options.size == 3 } || mc.first
    %w[3 -1 abc 1.5 0x9].each do |bad|
      assert_equal 0, saved(draft, { three.id => bad }, now: T0 + 1.minute).saved, "choice #{bad.inspect} must not be stored"
    end
    assert_equal 0, draft.answers.count
    assert_equal 1, saved(draft, { three.id => (three.options.size - 1).to_s }, now: T0 + 1.minute).saved, "control: the last option is accepted"
    refused_by_database { draft.answers.first.update_columns(choice_index: 6) }
    # Observed, harmless: Integer() reads "0x1" as hexadecimal, so it stores option 1, exactly what
    # posting "1" stores. Recorded so a stricter parser is a visible, deliberate change.
    assert_equal 1, saved(draft, { three.id => "0x1" }, now: T0 + 1.minute).saved
    assert_equal 1, draft.answers.find_by!(bank_question: three).choice_index

    assert written
    assert_equal 1, saved(draft, { written.id => "x" * 4100 }, now: T0 + 2.minutes).saved
    assert_equal 4000, draft.answers.find_by!(bank_question: written).answer_text.size, "observed: over-long text is truncated, not refused"
  end

  test "no answer before the start or after submit, at the service and at the trigger" do
    job = three_step_job!
    draft, secret = three_step_open!(job)
    q = draft.question_bank.questions.first
    assert_match(/Start the test first/, saved(draft, { q.id => "0" }, now: T0).error)
    refused_by_database { DraftAnswer.create!(application_draft: draft, bank_question: q, choice_index: 0, saved_at: T0) }

    post apply_cv_path(job.public_code, secret), params: { lamaran: { cv: three_step_pdf } }
    post apply_test_start_path(job.public_code, secret)
    draft.reload
    drawn = draft.questions.first
    assert_equal 1, saved(draft, { drawn.id => "0" }, now: T0 + 1.minute).saved
    post apply_submit_path(job.public_code, secret)
    assert draft.reload.submitted?
    assert_match(/already submitted/, saved(draft, { drawn.id => "1" }, now: T0 + 2.minutes).error)
    refused_by_database { draft.answers.first.update!(choice_index: 1, saved_at: T0 + 2.minutes) }
    refused_by_database { draft.update_columns(submitted_at: nil, job_application_id: nil) }
  end

  test "starting again keeps the draw and the deadline; the database refuses any change to them after the start" do
    job = three_step_job!
    draft, secret = three_step_started!(job)
    draw, due = draft.draw, draft.test_due_at
    travel 5.minutes
    post apply_test_start_path(job.public_code, secret)
    ApplicationDrafts::StartTest.call(draft.reload, now: Time.current, random: Random.new(99))
    draft.reload
    assert_equal draw, draft.draw
    assert_equal due, draft.test_due_at

    refused_by_database { draft.update_columns(time_limit_minutes: 60) }
    refused_by_database { draft.reload.update_columns(draw: draw.reverse) }
    refused_by_database { draft.reload.update_columns(test_due_at: due + 1.hour, test_started_at: draft.test_started_at + 1.hour) }
    refused_by_database { draft.reload.update_columns(grace_seconds: 600) }
    refused_by_database { draft.reload.update_columns(question_bank_id: QuestionBank.create!(job:, version: 99, created_by: staff_user("consultant")).id) }
    draft.reload.update_columns(channel_code: "ig") # control: an unrelated column still updates
  end

  test "the time limit is the bank's, not the request's: a posted time_limit is ignored" do
    job = three_step_job!
    params = three_step_details(job)
    params[:lamaran][:time_limit_minutes] = "60"
    params[:time_limit_minutes] = "60"
    post apply_start_path(job.public_code), params: params
    secret = response.location[%r{/d/([^/]+)/cv}, 1]
    assert_equal 30, ApplicationDraft.find_by_secret(job, secret).time_limit_minutes
  end

  test "the draw is stratified: with 8 + 2 questions over two activities every applicant gets 2 of the small activity" do
    job = three_step_job!(split: [8, 2])
    bank = QuestionBank.current_for(job)
    small = bank.questions.select { |q| q.prompt.start_with?("Technical B") }.map(&:id)
    assert_equal 2, small.size
    draws = (1..30).map { |seed| ApplicationDrafts::Draw.call(bank, random: Random.new(seed)) }
    draws.each do |ids|
      assert_equal 8, ids.size, "5 technical + 3 role"
      assert_equal ids.uniq, ids, "no question twice"
      technical = ids.first(5)
      assert(technical.all? { |id| bank.questions.find { |q| q.id == id }.technical? }, "technical first")
      assert_equal 2, (technical & small).size, "round-robin covers the small activity before testing the big one twice"
    end
    assert_operator draws.uniq.size, :>, 1, "random per applicant: 30 draws are not all the same"
  end

  test "a new bank version approved after the applicant started does not change the applicant's bank, draw or limit" do
    job = three_step_job!
    draft, secret = three_step_started!(job)
    before = draft.attributes.slice("question_bank_id", "draw", "time_limit_minutes", "test_due_at")
    consultant = staff_user("consultant")
    assert TestCases::SaveBank.call(job:, actor: consultant, action: "settings",
                                    params: { technical_draw: "5", role_draw: "3", time_limit_minutes: "45", new_version_reason: "Longer test" }).ok?
    v2 = QuestionBank.latest_for(job)
    assert_equal 2, v2.version
    assert TestCases::BankDecision.call(bank: v2, actor: consultant, action: "submit").ok?
    assert TestCases::BankDecision.call(bank: v2.reload, actor: staff_user("reviewer"), action: "approve", seen_digest: v2.content_digest).ok?
    assert_equal v2.id, QuestionBank.current_for(job).id

    get apply_test_path(job.public_code, secret)
    assert_response :success
    assert_equal before, draft.reload.attributes.slice("question_bank_id", "draw", "time_limit_minutes", "test_due_at")
    other, = three_step_started!(job, email: "budi@contoh.example")
    assert_equal [v2.id, 45], [other.question_bank_id, other.time_limit_minutes], "control: a new applicant gets the new version"
  end
end
