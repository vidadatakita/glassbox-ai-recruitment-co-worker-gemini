require "test_helper"

# Multi-tenant scoping: a client user (HR PIC, owner) reaches only their own company's jobs and
# everything under them; DataKita staff (no company) reach all. The TENANCY=single trigger is lifted
# for the test (session variable), as TENANCY=multi would.
class OrgScopeTest < ActionDispatch::IntegrationTest
  include TechnicalTestFactory

  setup do
    ActiveRecord::Base.connection.execute("SET glassbox.tenancy = 'multi'")
    @job = technical_test_job(open_gate: false)
    @application, = applicant!(@job)
    @s1 = s1_of(@application)
    @other = ClientCompany.create!(name: "PT Lain Sejahtera", address: "Jl. Lain 2", city: "Bandung", contact_email: "hr@lain.example")
    @other_hr = User.create!(email_address: "hr@lain.example", name: "HR Lain", role: "hr_pic", client_company: @other, password: "rahasia-uji-2026")
    @other_owner = User.create!(email_address: "owner@lain.example", name: "Owner Lain", role: "owner", client_company: @other, password: "rahasia-uji-2026")
  end

  teardown { ActiveRecord::Base.connection.execute("SET glassbox.tenancy = 'single'") }

  def with_env(values)
    before = values.keys.to_h { |k| [k, ENV[k]] }
    values.each { |k, v| ENV[k] = v }
    yield
  ensure
    before.each { |k, v| ENV[k] = v }
  end

  test "another company's HR PIC gets 404 on this company's job, applicant, participation and actions" do
    sign_in_as @other_hr
    get staff_jobs_path
    refute_includes response.body, @job.title, "not in the job list"

    [staff_job_path(@job), staff_job_brief_path(@job), staff_job_ad_path(@job), staff_application_path(@application),
     cv_staff_application_path(@application), staff_job_screening_report_path(@job)].each do |path|
      get path
      assert_response :not_found, path
    end
    post staff_participation_choice_path(@s1), params: { choice: "lanjut" }
    assert_response :not_found
    assert_nil @s1.reload.progression_choice
    post staff_application_letter_draft_path(@application)
    assert_response :not_found
  end

  test "the owner of this company still works; DataKita staff see every company's jobs" do
    sign_in_as staff_user("hr_pic")
    get staff_application_path(@application)
    assert_response :success

    sign_in_as staff_user("consultant")
    other_job = Job.create!(title: "Kasir Toko Lain", golongan: 1, client_company: @other)
    get staff_jobs_path
    assert_includes response.body, @job.title
    assert_includes response.body, other_job.title
  end

  test "the database refuses a choice or a salary by a user of another company" do
    error = refused_by_database do
      ProgressionChoice.create!(participation: @s1, choice: "lanjut", direction: "lanjut", actor: @other_hr, created_at: Time.current)
    end
    assert_match(/another company/, error.message)
    error = refused_by_database do
      SalaryAgreement.create!(job_application: @application, agreed_amount: 5_000_000, outside_band: false, decided_by: @other_owner, created_at: Time.current)
    end
    assert_match(/another company/, error.message)
  end

  test "settings and consent are per company, with the install-wide ones as the fallback" do
    SystemSetting.create!(key: "retention_days", value: "90", client_company: @other)
    assert_equal 90, SystemSetting.retention_days(company: @other)
    assert_equal SystemSetting.retention_days, SystemSetting.retention_days(company: @job.client_company), "no own row: the install-wide value"

    with_env("TENANCY" => "multi") { Portal::UpdateSetting.call(key: "retention_days", value: "60", actor: @other_hr) }
    assert_equal 60, SystemSetting.retention_days(company: @other)
    refute_equal 60, SystemSetting.retention_days, "another company's change never touches the install-wide value"
  end

  test "an unmatched link request reaches only DataKita staff; a matched one only its company" do
    LinkRequest.create!(job_code: "TIDAKADA", contact: "x@contoh.example")
    LinkRequest.create!(job_code: @job.public_code, job: @job, contact: "y@contoh.example")
    other_queue = Portal::WorkQueue.new(jobs: Job.visible_to(@other_hr))
    assert_empty other_queue.link_requests
    own = Portal::WorkQueue.new(jobs: Job.visible_to(staff_user("hr_pic")))
    assert_equal ["y@contoh.example"], own.link_requests.map(&:contact)
    staff = Portal::WorkQueue.new(jobs: Job.visible_to(staff_user("consultant")), unassigned: true)
    assert_equal 2, staff.link_requests.size
  end
end
