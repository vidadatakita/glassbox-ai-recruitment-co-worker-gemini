require "test_helper"
require "open3"
require_relative "portal_engine_support"

# Hunt item 7 (brief 02): silent failures. MailDelivery must record "failed" (never "sent") when
# delivery raises, the candidate must be told, the operator must see it in the work queue, and
# programming errors must NOT be swallowed. Plus the process holes found while reading:
# withdrawal and a closed S1 leaving applications nobody can decide.
class EnginePortalMailAndFailureTest < ActionDispatch::IntegrationTest
  include PortalEngineSupport

  setup do
    Rails.cache.clear
    ActionMailer::Base.deliveries.clear
    @job = portal_job
    open_portal(@job)
    @application, @token = submit!(@job)
  end

  # Builds a message whose delivery raises `error`.
  def failing_message(error)
    message = CandidateMailer.status_link(@application, "x")
    message.define_singleton_method(:deliver_now) { raise error }
    message
  end

  test "a delivery that raises an SMTP-class error is recorded failed, never sent" do
    require "net/smtp" # isolates the class list; the load-order hole has its own test below
    [Errno::ECONNREFUSED.new, Net::OpenTimeout.new, IOError.new("closed stream"),
     Net::SMTPAuthenticationError.new("535 auth"), OpenSSL::SSL::SSLError.new("tls")].each do |error|
      delivery = MailDelivery.deliver!(@application, "status_link") { failing_message(error) }
      assert_equal ["failed", error.class.name], [delivery.status, delivery.error_class], error.class.name
    end
    assert_equal 0, MailDelivery.where(status: "sent").count
  end

  # SocketError (getaddrinfo: the SMTP host name does not resolve) is the commonest
  # misconfiguration of a client's mail server. It is a plain StandardError and was missing from
  # the rescue list until the F1 fix (2026-10-10); this test guards against its removal.
  test "F1 fixed: an SMTP host that does not resolve (SocketError) is recorded as a failed delivery" do
    require "net/smtp"
    delivery = nil
    begin
      delivery = MailDelivery.deliver!(@application, "status_link") { failing_message(SocketError.new("getaddrinfo: Name or service not known")) }
    rescue SocketError
      flunk "SocketError escaped MailDelivery: the candidate gets a 500 and no failed row reaches the work queue"
    end
    assert_equal "failed", delivery.status
  end

  # The rescue names Net::SMTPError, which exists only after net/smtp is loaded. Before the F2
  # fix nothing loaded it under the :test delivery method, so ANY exception reaching that rescue
  # clause became NameError: no failed row, a 500 page. MailDelivery now requires net/smtp
  # itself. Run in a fresh process so no other test has loaded net/smtp first.
  test "F2 fixed: MailDelivery's rescue works in a process that never loaded net/smtp" do
    script = <<~'RUBY'
      begin
        MailDelivery.deliver!(JobApplication.new, "status_link") { raise Errno::ECONNREFUSED }
        puts "RESULT=no-exception"
      rescue NameError => e
        puts "RESULT=NameError #{e.message}"
      rescue => e
        puts "RESULT=rescued-then-#{e.class}"
      end
    RUBY
    out, status = Open3.capture2e({ "RAILS_ENV" => "test" }, "bin/rails", "runner", script, chdir: Rails.root.to_s)
    assert status.success?, "runner failed: #{out[-500..]}"
    result = out[/RESULT=.*/]
    assert result, "the probe printed nothing: #{out[-500..]}"
    refute_match(/NameError/, result, "the rescue clause itself raised: #{result}")
  end

  test "a programming error in the mail is NOT swallowed (the rescue is not too wide)" do
    require "net/smtp"
    assert_raises(NoMethodError) do
      MailDelivery.deliver!(@application, "status_link") { failing_message(NoMethodError.new("undefined method")) }
    end
    assert_raises(ArgumentError) { MailDelivery.deliver!(@application, "unknown_kind") { failing_message(IOError.new) } }
    assert_equal 0, MailDelivery.count
  end

  test "an offer-code mail failure tells the candidate it was not sent, and appears in the work queue" do
    require "net/smtp"
    application, token = offer_ready!(@job, email: "dua@uji.example")
    decide_stage!(@application, "S1", outcome: "eliminate", score: 30, close: false)
    close_s1_and_pass_s5!(@job, [application])
    upload_offer!(application)
    original = CandidateMailer.method(:offer_code)
    CandidateMailer.define_singleton_method(:offer_code) do |*args|
      message = original.call(*args)
      message.define_singleton_method(:deliver_now) { raise Errno::ECONNREFUSED }
      message
    end
    begin
      post candidate_status_offer_code_path(token)
    ensure
      CandidateMailer.singleton_class.send(:remove_method, :offer_code)
    end
    follow_redirect!
    assert_includes response.body, "The e-mail could not be sent"
    refute_includes response.body, "The code has been sent to your e-mail"
    assert_equal ["failed"], MailDelivery.where(job_application: application).pluck(:status)
    sign_in_as staff_user("consultant")
    get staff_work_queue_path
    assert_includes response.body, "Errno::ECONNREFUSED"
  end

  test "a successful delivery is recorded sent and the mail goes to the address on file only" do
    Portal::ReissueLink.call(job_code: @job.public_code, email: "rina@uji.example")
    assert_equal ["sent"], MailDelivery.pluck(:status)
    assert_equal [["rina@uji.example"]], ActionMailer::Base.deliveries.map(&:to)
  end

  # Pasal 40 ends processing. Before the F3 fix the withdrawn application kept an undecided
  # participation in the open stage, and Stages::Close refused while anyone was undecided: one
  # withdrawal blocked the stage for every other candidate.
  test "F3 fixed: a withdrawal does not leave the open stage unclosable" do
    s1 = stage_of(@job, "S1")
    Stages::Open.call(stage: s1)
    other, = submit!(@job, email: "lain@uji.example")
    decide_stage!(other, "S1", outcome: "pass", close: false)
    Portal::CandidateActions.new(@application).withdraw_consent!
    begin
      Stages::Close.call(stage: s1.reload)
    rescue Stages::Close::Undecided => e
      flunk "the withdrawn application blocks closing S1 for everyone else: #{e.message}"
    end
    assert_equal "closed", s1.reload.status
  end

  test "F3 fixed: a withdrawal while S1 is open is decided by rule 'withdrew', superseding an earlier pass" do
    s1 = stage_of(@job, "S1")
    Stages::Open.call(stage: s1)
    participation = decide_stage!(@application, "S1", outcome: "pass", close: false)
    Portal::CandidateActions.new(@application).withdraw_consent!
    decision = participation.reload.current_decision
    assert_equal ["withdrew", "withdrew"], [decision.reason_code, participation.attendance]
    Stages::Close.call(stage: s1.reload)
  end

  test "F3 fixed: a withdrawal while S1 is still a draft is decided when S1 opens" do
    Portal::CandidateActions.new(@application).withdraw_consent!
    s1 = stage_of(@job, "S1")
    Stages::Open.call(stage: s1)
    assert_equal "withdrew", @application.participations.find_by!(stage: s1).current_decision&.reason_code
  end

  # F1 fix: re-issue revokes the old links only after the new one was actually sent.
  test "F1 fixed: a failed re-issue keeps the old link working, kills the unsent new one, and shows in the work queue" do
    original = CandidateMailer.method(:status_link)
    CandidateMailer.define_singleton_method(:status_link) do |*args|
      message = original.call(*args)
      message.define_singleton_method(:deliver_now) { raise SocketError, "getaddrinfo: Name or service not known" }
      message
    end
    begin
      post link_requests_path, params: { job_code: @job.public_code, email: "rina@uji.example", commit: "Kirim link baru" }
    ensure
      CandidateMailer.singleton_class.send(:remove_method, :status_link)
    end
    assert_response :success
    assert OneTimeLink.live("candidate_status", @token), "the candidate's only working link was revoked by a failed send"
    assert_equal 1, OneTimeLink.where(subject: @application, revoked_at: nil).count, "an unsent link is still live"
    assert_equal ["failed"], MailDelivery.where(job_application: @application).pluck(:status)
    sign_in_as staff_user("consultant")
    get staff_work_queue_path
    assert_includes response.body, "SocketError"
  end
end
