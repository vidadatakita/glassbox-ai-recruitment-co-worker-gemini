require "test_helper"

# Feature 08 (D62 h5): "Expected salary (optional)" on the Lamar data step. Optional, both
# ends or neither, integer rupiah per month; never sent to the AI, never scored.
class LamarExpectedSalaryTest < ActionDispatch::IntegrationTest
  # The portal's rate limits (D41) count requests in Rails.cache, which outlives a test inside one
  # worker. Without this reset an earlier test's submits can push these over the limit and the
  # submit answers 429 (seen 2026-10-10 21:0x on lamar_expected_salary_test.rb:29).
  setup { Rails.cache.clear }

  include ActiveJob::TestHelper
  include ScreeningFactory

  def lamaran(job, **overrides) = application_params(job, **overrides).except(:knockout)

  test "the field is on step 2, optional, and says it is not used to judge the application" do
    job = portal_job
    open_portal(job)
    post lamar_check_path(job.public_code), params: { knockout: answers_for(job) }
    assert_select "legend", text: "Expected salary (optional)"
    assert_select "#lamaran_expected_salary_min:not([required])"
    assert_select "#lamaran_expected_salary_max:not([required])"
    assert_includes response.body, "Not used to judge your application."
    doc = Nokogiri::HTML(response.body)
    assert_empty doc.css("form form")
    assert_empty doc.css("button[disabled]")
  end

  test "typed the Indonesian way it is stored as integer rupiah; left empty it stores nothing" do
    job = portal_job
    open_portal(job)
    post lamar_path(job.public_code), params: { knockout: answers_for(job),
                                                lamaran: lamaran(job, expected_salary_min: "Rp 7.000.000", expected_salary_max: "8.500.000", consent_token: shown_consent_token) }
    assert_response :success
    assert_equal [7_000_000, 8_500_000], JobApplication.last.slice(:expected_salary_min, :expected_salary_max).values
    post lamar_path(job.public_code), params: { knockout: answers_for(job),
                                                lamaran: lamaran(job, email: "dua@uji.example", consent_token: shown_consent_token) }
    assert_response :success
    assert_equal [nil, nil], JobApplication.last.slice(:expected_salary_min, :expected_salary_max).values, "control: optional"
  end

  test "minimum above maximum is refused at the field, typed values kept, nothing stored" do
    job = portal_job
    open_portal(job)
    post lamar_path(job.public_code), params: { knockout: answers_for(job),
                                                lamaran: lamaran(job, expected_salary_min: "9.000.000", expected_salary_max: "8.000.000", consent_token: shown_consent_token) }
    assert_response :unprocessable_entity
    assert_select "#lamaran_salary-error", text: "The minimum salary cannot be more than the maximum."
    assert_select "#lamaran_expected_salary_min[value=?]", "9.000.000"
    assert_equal 0, JobApplication.count
  end

  test "the database refuses a half range or an inverted range (CHECK job_applications_expected_salary)" do
    job = portal_job
    open_portal(job)
    application, = submit!(job)
    refused_by_database { application.update_columns(expected_salary_min: 5_000_000) }
    refused_by_database { application.update_columns(expected_salary_min: 6, expected_salary_max: 5) }
    application.update_columns(expected_salary_min: 5, expected_salary_max: 5) # control: a valid range
  end

  test "the expected salary never reaches the Gemini API request" do
    job = screening_job
    fake = FakeGemini.new(gemini_message(criteria_for(job)))
    with_ai(fake) do
      application, = submit!(job, cv: pdf_upload(pdf_with_text(FIXTURE_CV)), expected_salary_min: "7.654.321", expected_salary_max: "8.765.432")
      assert_equal 7_654_321, application.expected_salary_min, "control: the value was stored"
      screen_and_release! # D51: a named reviewer releases the held CV, then the one call is made
    end
    body = fake.bodies.sole
    %w[7654321 7.654.321 8765432 8.765.432].each { |v| refute_includes body, v }
  end
end
