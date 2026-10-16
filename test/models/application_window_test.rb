require "test_helper"

# BP §3.6 A, C: the window is derived, never stored; auto-close by time or quota needs no job.
class ApplicationWindowTest < ActiveSupport::TestCase
  setup { @job = portal_job }

  test "a job never opened is never_opened" do
    assert_equal :never_opened, ApplicationWindow.new(@job).state
  end

  test "closes_at boundary: open one minute before, closed at the stored WIB time and after" do
    closes = Time.zone.parse("2026-10-24 17:00")      # WIB, Time.zone is Asia/Jakarta
    open_portal(@job, closes_at: closes, now: closes - 2.hours)
    assert_equal "2026-10-24 10:00:00 UTC", closes.utc.to_s, "17.00 WIB is stored as 10.00 UTC"
    assert ApplicationWindow.new(@job, now: closes - 1.minute).open?
    assert_equal :closed_by_date, ApplicationWindow.new(@job, now: closes).state
    assert_equal :closed_by_date, ApplicationWindow.new(@job, now: closes + 1.minute).state
  end

  test "quota: the application that reaches the quota is accepted, the next is refused" do
    open_portal(@job, quota: 2)
    submit!(@job, email: "a@uji.example")
    assert ApplicationWindow.new(@job).open?, "1 of 2: still open"
    submit!(@job, email: "b@uji.example")
    assert_equal :closed_by_quota, ApplicationWindow.new(@job).state
    assert_raises(Portal::SubmitApplication::Closed) { submit!(@job, email: "c@uji.example") }
    assert_equal 2, @job.job_applications.count
  end

  test "an HR close wins over an open time window" do
    open_portal(@job, closes_at: 1.day.from_now)
    Portal::WindowChange.close!(job: @job, actor: staff_user("hr_pic"))
    assert_equal :closed_by_hr, ApplicationWindow.new(@job).state
  end
end
