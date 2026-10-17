require "test_helper"
require Rails.root.join("db/seeds/demo_screening_report").to_s

# Independent test pass 2, three roles (GlassBox Team, 17 Oct 2026): three rules the role rename could have
# broken. The retired "consultant" (who saw contacts and answers always) is now an hr_admin, who decides
# blind; merging the two would leak applicant contacts and answers into the blind decision.
#   (a) ScreeningReport::Visibility#contacts? : superadmin always; hr_admin only once the screening is
#       confirmed; hr_manager never. Checked on the rule, the report screen and the xlsx export.
#   (b) TechnicalTests.answer_downloadable_by? : hr_manager and superadmin always; hr_admin only once
#       confirmed; anyone else never.
#   (c) Job#ad_writable_by? : hr_admin and superadmin, draft or live; hr_manager and unknown roles never.
#
# Mutants for these files were NOT run (outside the agreed window). The ones that should turn these red:
#   contacts?       -> `@user.role.in?(%w[superadmin hr_admin])` (drop the confirmed? branch)
#   contacts?       -> add `|| @user.role == "hr_manager"`
#   answer rule     -> move "hr_admin" into the always branch
#   answer rule     -> drop "superadmin" from the always branch
#   ad_writable_by? -> add "hr_manager" to either list
class CupRoleVisibilityTest < ActionDispatch::IntegrationTest
  Actor = Struct.new(:id, :role)
  RETIRED = %w[hr_pic consultant reviewer owner admin].freeze

  setup do
    set_retention
    publish_consent
    @open_job, @closed_job = DemoScreeningReport.run(company:, hr: staff_user("hr_pic"), consultant: staff_user("consultant"),
                                                     reviewer: staff_user("reviewer"))
    @super = staff_user("superadmin")
    @admin = staff_user("consultant") # the retired consultant, now an hr_admin
    @manager = staff_user("reviewer")
    assert_not CandidateIdentity.screening_confirmed?(@open_job), "fixture: the open job is still blind"
    assert CandidateIdentity.screening_confirmed?(@closed_job), "fixture: the closed job is confirmed"
  end

  def contact_strings = /contoh\.example|0812-0000/

  def xlsx_text(body)
    require "zip"
    Zip::File.open_buffer(StringIO.new(body)) do |zip|
      return zip.glob("xl/**/*.xml").map { |entry| zip.read(entry.name) }.join(" ")
    end
  end

  # --- (a) contacts ---------------------------------------------------------------------------------

  test "contacts? per role, blind and confirmed" do
    expected = { @super => [true, true], @admin => [false, true], @manager => [false, false] }
    expected.each do |user, (blind, confirmed)|
      assert_equal blind, ScreeningReport::Visibility.new(@open_job, user).contacts?, "#{user.role} on the blind job"
      assert_equal confirmed, ScreeningReport::Visibility.new(@closed_job, user).contacts?, "#{user.role} on the confirmed job"
    end
    [nil, "visitor", *RETIRED].each do |role|
      assert_not ScreeningReport::Visibility.new(@closed_job, Actor.new(nil, role)).contacts?, role.inspect
    end
  end

  test "the blind report screen and xlsx give an hr_admin no contacts; the superadmin gets them" do
    sign_in_as @admin
    get staff_job_screening_report_path(@open_job)
    assert_response :success
    assert_no_match contact_strings, response.body, "the hr_admin screen shows contacts while blind"
    get staff_job_screening_report_export_path(@open_job)
    assert_response :success
    assert_no_match contact_strings, xlsx_text(response.body), "the hr_admin export carries contacts while blind"
    sign_out

    sign_in_as @super
    get staff_job_screening_report_export_path(@open_job)
    assert_match contact_strings, xlsx_text(response.body), "control: the superadmin export carries contacts (the strings are findable)"
  end

  test "an hr_manager export never carries contacts, even after confirmation" do
    sign_in_as @manager
    get staff_job_screening_report_export_path(@closed_job)
    if response.successful?
      assert_no_match contact_strings, xlsx_text(response.body)
    else
      assert_response :redirect # no access at all is also no contact
    end
    sign_out
    sign_in_as @admin
    get staff_job_screening_report_export_path(@closed_job)
    assert_match contact_strings, xlsx_text(response.body), "control: the hr_admin export carries contacts once confirmed"
  end

  # --- (b) technical-test answers -------------------------------------------------------------------

  test "answer download per role, blind and confirmed" do
    expected = { @super => [true, true], @admin => [false, true], @manager => [true, true] }
    expected.each do |user, (blind, confirmed)|
      assert_equal blind, TechnicalTests.answer_downloadable_by?(user, @open_job), "#{user.role} on the blind job"
      assert_equal confirmed, TechnicalTests.answer_downloadable_by?(user, @closed_job), "#{user.role} on the confirmed job"
    end
    [nil, "visitor", *RETIRED].each do |role|
      assert_not TechnicalTests.answer_downloadable_by?(Actor.new(nil, role), @closed_job), role.inspect
    end
    assert_not TechnicalTests.answer_downloadable_by?(nil, @closed_job)
  end

  # --- (c) who writes the ad ------------------------------------------------------------------------

  test "ad_writable_by? per role, draft and live" do
    draft = Job.new(ad_approved_at: nil)
    live = Job.new(ad_approved_at: Time.current)
    [draft, live].each do |job|
      state = job.ad_approved_at ? "live" : "draft"
      assert job.ad_writable_by?(@super), "superadmin, #{state}"
      assert job.ad_writable_by?(@admin), "hr_admin, #{state}"
      assert_not job.ad_writable_by?(@manager), "hr_manager, #{state}"
      [nil, "visitor", *RETIRED].each { |role| assert_not job.ad_writable_by?(Actor.new(nil, role)), "#{role.inspect}, #{state}" }
      assert_not job.ad_writable_by?(nil)
    end
  end
end
