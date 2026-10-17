require "test_helper"

# Independent test pass, posting flow of 17 Oct 2026, through the real routes and rendered pages: the taken-down
# approval route, the house form rules on the changed screens (no disabled submit, no form inside a
# form, named submit buttons keep name/value, each parameter once, redirect on success), the apply
# page before the portal opens, and live code that still points at the old approval step.
class CupPostingFlowScreensTest < ActionDispatch::IntegrationTest
  CLEAN_TEXT = "About this role\nWe need a warehouse administrator in Bekasi.".freeze
  RULE_TEXT = "About this role\nFemale, max 28 years old.".freeze

  setup do
    Rails.cache.clear
    set_retention
    publish_consent(at: 2.days.ago)
  end

  def draft_job(text: CLEAN_TEXT)
    job = briefed_job(ad: false)
    job.update_columns(ad_text: text, ad_flags: Briefs::AdCheck.rule_flags(text.to_s), ad_approved_at: nil, ad_approved_by_id: nil)
    job.reload
  end

  # Every form on the page: no nested form, no disabled control or disable-with, every submit button
  # a named submit button carries its value, and no field name (other than array fields) appears twice in one form.
  def assert_house_form_rules
    doc = Nokogiri::HTML(response.body)
    forms = doc.css("form")
    assert forms.any?, "no form on #{request.path}: the check would pass on an empty page"
    forms.each do |form|
      assert_empty form.css("form"), "nested form on #{request.path}"
      assert_empty form.css("[disabled], [data-disable-with], [data-turbo-submits-with]"), "disabled control in #{form['action']}"
      # A named button must carry its value; a form with several submit buttons must name each one,
      # or the server cannot tell which was pressed. (A lone unnamed button, e.g. Sign out, is fine.)
      buttons = form.css("button[type=submit], input[type=submit]")
      buttons.each do |button|
        named = button["name"].present?
        assert button["value"].present?, "named submit button without a value in #{form['action']}" if named
        assert named, "unnamed submit button beside others in #{form['action']}: #{button.to_html[0, 120]}" if buttons.size > 1
      end
      names = form.css("input[name], textarea[name], select[name]").reject { |f| f["type"] == "submit" }.map { |f| f["name"] }.reject { |n| n.end_with?("[]") }
      assert_equal names.uniq, names, "a parameter appears twice in #{form['action']}"
    end
    doc
  end

  test "PATCH approve_ad answers 404 and changes nothing on the job" do
    job = draft_job
    sign_in_as staff_user("hr_pic")
    assert_not respond_to?(:approve_ad_staff_job_path), "the approval route helper is still drawn"
    patch "#{staff_job_path(job)}/approve_ad", params: { flags_checked: "1", flags_reason: "Invented." }
    assert_response :not_found
    job.reload
    assert_nil job.ad_approved_at
    assert_nil job.ad_approved_by_id
    assert_empty job.brief_changes.where(step: "ad")
  end

  test "the portal card of a written draft offers Open portal under the house form rules, and no approval form" do
    job = draft_job
    sign_in_as staff_user("hr_pic")
    get staff_job_path(job)
    assert_response :success
    doc = assert_house_form_rules
    open_form = doc.css("form[action='#{staff_job_portal_open_path(job)}']")
    assert_equal 1, open_form.size, "exactly one Open portal form"
    assert_equal "true", open_form.first["data-submit-guard"]
    assert_equal 1, open_form.css("button[name=commit][value='Open portal']").size
    assert_empty doc.css("form[action*='approve_ad']")
    assert_not_includes response.body, "Approve job ad"
    assert_select "#applicant-portal", 1
  end

  test "the portal card offers no open to a reviewer or the owner" do
    job = draft_job
    %w[reviewer owner].each do |role|
      sign_in_as staff_user(role)
      get staff_job_path(job)
      assert_response :success
      assert_select "form[action=?]", staff_job_portal_open_path(job), 0
      sign_out
    end
  end

  test "the ad page of a draft keeps the house form rules and has no approval form" do
    job = draft_job
    sign_in_as staff_user("hr_pic")
    get staff_job_ad_path(job)
    assert_response :success
    doc = assert_house_form_rules
    assert_empty doc.css("form[action*='approve_ad']")
    assert_empty doc.css("input[name=flags_checked]"), "the old approval tick is still on the page"
  end

  test "a rule-flagged draft comes back with one required reason field; a whitespace reason saves nothing" do
    job = draft_job(text: nil)
    sign_in_as staff_user("consultant")
    post staff_job_ad_path(job), params: { ad_text: RULE_TEXT, flags_reason: "   \n " }
    assert_response :unprocessable_content
    assert_nil job.reload.ad_text
    doc = assert_house_form_rules
    assert_equal 1, doc.css("textarea[name=flags_reason][required]").size
  end

  test "a draft save redirects to the portal card; Open portal redirects and approves under the signed-in person" do
    job = draft_job(text: nil)
    consultant = staff_user("consultant")
    sign_in_as consultant
    post staff_job_ad_path(job), params: { ad_text: CLEAN_TEXT }
    assert_redirected_to staff_job_path(job, anchor: "applicant-portal")
    assert_includes [302, 303], response.status

    post staff_job_portal_open_path(job), params: { commit: "Open portal", closes_at: "", quota: "" }
    assert_redirected_to staff_job_path(job)
    assert_includes [302, 303], response.status
    assert_equal consultant.id, job.reload.ad_approved_by_id
    follow_redirect!
    assert_includes response.body, "Applicant portal opened."
  end

  test "a second Open portal submit is refused with a redirect and writes nothing more" do
    job = draft_job
    sign_in_as staff_user("hr_pic")
    post staff_job_portal_open_path(job), params: { commit: "Open portal" }
    post staff_job_portal_open_path(job), params: { commit: "Open portal" }
    assert_redirected_to staff_job_path(job)
    assert_match(/opened before/, flash[:alert])
    assert_equal 1, job.application_window_events.count
    assert_equal 1, job.brief_changes.where(step: "ad").count { |c| c.changes_made.key?("ad_approved_at") }
  end

  test "a refused open redirects with the reason, never a 200 that looks like success" do
    job = draft_job(text: nil)
    sign_in_as staff_user("hr_pic")
    post staff_job_portal_open_path(job), params: { commit: "Open portal" }
    assert_redirected_to staff_job_path(job)
    assert_match(/not been written/, flash[:alert])
    assert_nil job.reload.ad_approved_at
    assert_equal :never_opened, ApplicationWindow.new(job).state
  end

  test "the apply page shows the ad only while the portal is open" do
    job = draft_job
    get lamar_path(job.public_code)
    assert_not_includes response.body, "warehouse administrator", "a never-opened vacancy shows its ad"
    open_portal(job)
    get lamar_path(job.public_code)
    assert_response :success
    assert_includes response.body, "warehouse administrator"
    Portal::WindowChange.close!(job:, actor: staff_user("hr_pic"))
    get lamar_path(job.public_code)
    assert_not_includes response.body, "warehouse administrator", "a closed vacancy shows its ad"
  end

  # --- Dead references -----------------------------------------------------------------------------

  STALE = [/approve_ad_staff_job/, /approve the job ad/i, /job ad can be approved/i, /can approve the job ad/i,
           /then approved by HR/i, /awaits HR approval/i, /awaiting job ad approval/i].freeze

  # Code and UI text only: Ruby comment lines and ERB comments are dropped, so a note that records
  # the take-down does not count.
  def live_text(path, source)
    source = source.gsub(/<%#.*?%>/m, "") if path.end_with?(".erb")
    source.lines.reject { |line| line.lstrip.start_with?("#", "//") }.join
  end

  def stale_hits(path, source)
    text = live_text(path, source)
    STALE.select { |pattern| text.match?(pattern) }.map { |pattern| "#{path}: #{pattern.source}" }
  end

  test "the stale-reference scan sees live text and ignores comments (positive control)" do
    assert_not_empty stale_hits("x.erb", "<p>Approve the job ad now.</p>")
    assert_not_empty stale_hits("x.rb", "redirect_to x, notice: \"Brief completed. HR can approve the job ad.\"")
    assert_empty stale_hits("x.erb", "<%# The separate Approve the job ad step was taken down %>")
    assert_empty stale_hits("x.rb", "  # approve the job ad was removed")
  end

  test "no live code calls the approval route and no screen tells anyone to approve the job ad" do
    files = Dir[Rails.root.join("app/{controllers,views,helpers,javascript,mailers,services,models}/**/*.{rb,erb,js}")]
    assert files.size > 50, "the scan read #{files.size} files: the glob is wrong"
    # The kept, unrouted action is allowed to keep its own wording.
    files -= [Rails.root.join("app/controllers/staff/jobs_controller.rb").to_s]
    hits = files.flat_map { |f| stale_hits(f.delete_prefix("#{Rails.root}/"), File.read(f)) }
    assert_empty hits, "live references to the taken-down approval step:\n#{hits.join("\n")}"
  end

  test "the submit guard never disables a control (code lines, not its comments)" do
    path = "app/javascript/submit_guard.js"
    code = live_text(path, File.read(Rails.root.join(path)))
    assert_includes code, "dataset.submitted", "the guard's code was not read"
    [/\.disabled\s*=/, /setAttribute\(\s*["']disabled/, /disable-with/, /turbo-submits-with/].each do |pattern|
      assert_no_match pattern, code
    end
    assert_match(/\.disabled\s*=/, live_text("x.js", "button.disabled = true"), "positive control: the pattern sees a disabling line")
  end
end
