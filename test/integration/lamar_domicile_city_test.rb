require "test_helper"

# D54: optional "City of residence" on the Lamar data step: city or kabupaten only, never an address,
# never sent to the AI, shown in the report only under the contact rule.
class LamarDomicileCityTest < ActionDispatch::IntegrationTest
  # The portal's rate limits (D41) count requests in Rails.cache, which outlives a test inside one
  # worker. Without this reset an earlier test's submits can push these over the limit and the
  # submit answers 429 (seen 2026-10-10 21:0x on lamar_expected_salary_test.rb:29).
  setup { Rails.cache.clear }

  include ActiveJob::TestHelper
  include ScreeningFactory

  def lamaran(job, **overrides) = application_params(job, **overrides).except(:knockout).merge(consent_token: shown_consent_token)

  test "optional field on step 2 with suggestions; stored squeezed; empty stores nothing" do
    job = portal_job
    open_portal(job)
    post lamar_check_path(job.public_code), params: { knockout: answers_for(job) }
    assert_select "#lamaran_domicile_city:not([required])[maxlength='60'][list]"
    assert_select "label[for=lamaran_domicile_city]", text: "City of residence (optional)"
    post lamar_path(job.public_code), params: { knockout: answers_for(job), lamaran: lamaran(job, domicile_city: "  Kabupaten   Bekasi ") }
    assert_response :success
    assert_equal "Kabupaten Bekasi", JobApplication.last.domicile_city
    post lamar_path(job.public_code), params: { knockout: answers_for(job), lamaran: lamaran(job, email: "dua@uji.example") }
    assert_nil JobApplication.last.domicile_city, "control: optional"
  end

  test "an address is refused at the field, the typed value kept, nothing stored" do
    job = portal_job
    open_portal(job)
    ["Jl. Melati No 5", "RT 03 RW 05 Jatiasih", "Bekasi 17411", "Kel. Jatiasih", "x" * 61].each do |typed|
      post lamar_path(job.public_code), params: { knockout: answers_for(job), lamaran: lamaran(job, domicile_city: typed) }
      assert_response :unprocessable_entity, typed
      assert_select "#lamaran_domicile_city-error", text: /city or regency/i
      assert_select "#lamaran_domicile_city[value=?]", typed
    end
    assert_equal 0, JobApplication.count
  end

  test "the database refuses digits or an over-long value (CHECK job_applications_domicile_city_shape)" do
    job = portal_job
    open_portal(job)
    application, = submit!(job)
    refused_by_database { application.update_columns(domicile_city: "Bekasi 17411") }
    refused_by_database { application.update_columns(domicile_city: "  ") }
    application.update_columns(domicile_city: "Bekasi") # control
  end

  test "the city never reaches the Gemini API request" do
    job = screening_job
    fake = FakeGemini.new(gemini_message(criteria_for(job)))
    with_ai(fake) do
      application, = submit!(job, cv: pdf_upload(pdf_with_text(FIXTURE_CV)), domicile_city: "Pangkalpinang")
      assert_equal "Pangkalpinang", application.domicile_city, "control: the value was stored"
      screen_and_release!
    end
    refute_includes fake.bodies.sole, "Pangkalpinang"
  end
end
