require "test_helper"

# C2 screen: the fairness table on demand. Gemini is stubbed at the HTTP boundary (FakeGemini), so
# the five request bodies the real client built are the ones compared. Risks hunted: a difference
# on identical bytes being shown as bias; a redaction gap hidden behind identical scores; the admin
# or an incomplete brief reaching the screen; the house form rules (no nested form, no disabled
# control, the submit button keeps its name and value); a model or prompt name on screen.
class FairnessCheckScreenTest < ActionDispatch::IntegrationTest
  include ScreeningFactory

  setup do
    @job = screening_job
    @hr = staff_user("hr_pic")
  end

  def answer(sebaiknya: "3")
    quotes = { "wajib" => "D3 Logistics Management", "sebaiknya" => "Warehouse Admin at PT Logistik Makmur",
               "nilai_tambah" => "Holds a SIM C driving licence" }
    Screening::Rubric.for(@job).criteria.map do |c|
      { id: c.key, judgement: { "wajib" => "met", "sebaiknya" => sebaiknya, "nilai_tambah" => "2" }.fetch(c.tier), quote: quotes.fetch(c.tier) }
    end
  end

  def run_with(replies)
    fake = FakeGemini.new
    with_ai(fake) do
      replies.each { |r| fake.push(r) }
      post staff_job_fairness_check_path(@job)
    end
    fake
  end

  def assert_house_rules
    doc = Nokogiri::HTML(response.body)
    assert_select "form form", { count: 0 }, "a form inside a form (house hard rule)"
    assert_empty doc.css("button[disabled], input[type=submit][disabled], [data-disable-with]"), "disabled submit"
    button = doc.at_css("form.fairness-check__run button[type=submit]")
    assert_equal %w[commit run], [button["name"], button["value"]], "the submit button keeps its name and value"
    # The tier badge names the model on purpose (FLOW §9 rule 3); prompt names, hashes and token counts never appear.
    refute_match(/prompt|sha-?256|digest|token/i, doc.css("body").text, "no prompt, hash or token word on screen")
  end

  test "show: the variants without a model call, Tier HIGH, the method sentence, identical bytes for every swap" do
    sign_in_as @hr
    get staff_job_fairness_check_path(@job)
    assert_response :success
    assert_includes response.body, "Tier HIGH"
    assert_includes response.body, "The swap is applied in the original CV text before redaction; identical redacted bytes prove the redaction, identical scores prove the model saw no difference."
    assert_select "#fairness-variant-name .portal-state", text: "Identical bytes reached the model"
    assert_select "#fairness-variant-gender .portal-state", text: "Identical bytes reached the model"
    assert_select "#fairness-variant-religion .portal-state", text: "Identical bytes reached the model"
    assert_select "#fairness-variant-merit_control .portal-state", text: "Different on purpose"
    assert_select ".fairness-check__scores", count: 0
    assert_house_rules
  end

  test "run: identical scores show every swap as same as the base, and the control row as moved" do
    sign_in_as @hr
    fake = run_with([gemini_message(answer), gemini_message(answer), gemini_message(answer), gemini_message(answer), gemini_message(answer(sebaiknya: "1"))])
    assert_response :success
    assert_equal 5, fake.requests.size
    assert_select ".fairness-check__method .portal-state", text: "Passed"
    assert_select "#fairness-variant-gender .portal-state", text: "Same as the base"
    assert_select "#fairness-variant-merit_control .portal-state", text: "Score moved, as it must"
    assert_select ".fairness-check__scores .fairness-check__cell--differs", count: 0
    assert_select ".fairness-check__scores .portal-state", { text: "differs", count: 0 }
    assert_house_rules
  end

  test "run: a different answer on identical bytes is labelled model variance, never bias; the cell says differs" do
    sign_in_as @hr
    run_with([gemini_message(answer), gemini_message(answer), gemini_message(answer(sebaiknya: "2")), gemini_message(answer), gemini_message(answer(sebaiknya: "1"))])
    assert_response :success
    assert_select "#fairness-variant-gender .portal-state", text: "Same input, different model answer"
    assert_select "#fairness-variant-gender .portal-state", { text: "Identical bytes reached the model", count: 1 }
    assert_select ".fairness-check__method .portal-state", text: "Needs a look"
    assert_select ".fairness-check__scores .portal-state", text: "differs"
    body = Nokogiri::HTML(response.body).css("body").text
    refute_match(/\bbias\b(?!\.)/i, body.gsub("never bias", ""), "no row may be labelled as bias")
    assert_house_rules
  end

  test "run: a provider error on one variant is shown as no answer, the rest still render" do
    sign_in_as @hr
    run_with([gemini_message(answer), gemini_error(503, "UNAVAILABLE"), gemini_message(answer), gemini_message(answer), gemini_message(answer(sebaiknya: "1"))])
    assert_response :success
    assert_select "#fairness-variant-name .portal-state", text: "No answer from the AI for this variant"
    assert_select "#fairness-variant-religion .portal-state", text: "Same as the base"
    assert_house_rules
  end

  test "the admin and the owner are sent back; an incomplete brief is refused with a plain message; AI off is a plain message" do
    sign_in_as staff_user("admin")
    get staff_job_fairness_check_path(@job)
    assert_redirected_to staff_jobs_path
    sign_in_as staff_user("owner")
    get staff_job_fairness_check_path(@job)
    assert_redirected_to staff_jobs_path

    sign_in_as @hr
    @job.update_columns(brief_status: "draft")
    get staff_job_fairness_check_path(@job)
    assert_redirected_to staff_job_path(@job)
    follow_redirect!
    assert_includes response.body, "The vacancy brief is not complete yet."
    @job.update_columns(brief_status: "complete")

    Screening::Config.stub(:enabled?, false) { post staff_job_fairness_check_path(@job) }
    assert_redirected_to staff_job_fairness_check_path(@job)
    follow_redirect!
    assert_includes response.body, "AI screening is off. No credentials are configured."
  end
end
