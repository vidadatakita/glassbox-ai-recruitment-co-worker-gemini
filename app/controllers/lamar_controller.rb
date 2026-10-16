# Screen 10 Lamar (BP §3.6 B1). Two steps: the knockout questions first, so a candidate who
# cannot qualify stops before typing any personal data (nothing is stored), then the short form.
# The window is checked on every request, and again by SubmitApplication inside a lock.
class LamarController < CandidateController
  # TD §3/§7: the public apply page is the one place a spike or a script arrives. Numbers and the
  # reason they are loose per IP: Glassbox::Settings::RATE_LIMITS (D41).
  LIMITS = Glassbox::Settings::RATE_LIMITS
  rate_limit to: LIMITS[:lamar_per_ip][:to], within: LIMITS[:lamar_per_ip][:within].seconds,
             only: %i[check create], name: "lamar-ip",
             with: -> { render "lamar/too_many", status: :too_many_requests }
  rate_limit to: LIMITS[:lamar_per_form][:to], within: LIMITS[:lamar_per_form][:within].seconds,
             only: :create, name: "lamar-form",
             by: -> { Digest::SHA256.hexdigest(params.dig(:lamaran, :consent_token).presence || "no-form:#{request.remote_ip}") },
             with: -> { render "lamar/too_many", status: :too_many_requests }

  before_action :load_job

  def show
    @window = ApplicationWindow.new(@job)
    return render("lamar/closed", status: :ok) unless @window.open?

    @answers = {}
  end

  # Step 1: knockout answers only. A "No" (stored value "tidak") ends here, politely, and stores nothing.
  def check
    @window = ApplicationWindow.new(@job)
    return render("lamar/closed", status: :gone) unless @window.open?

    @answers = knockout_params
    if @job.knockout_questions.any? { |q| !Portal::SubmitApplication::ANSWERS.include?(@answers[q.id.to_s]) }
      @errors = ["Answer every requirement question with Yes or No."]
      return render(:show, status: :unprocessable_entity)
    end
    return render("lamar/not_eligible") if @answers.value?("tidak")

    load_consent_shown
    render :form
  end

  def create
    # Closed first, before any validation: a closed portal answers "closed" (410) whatever the
    # form holds (test engine F14). SubmitApplication checks again inside its lock.
    @window = ApplicationWindow.new(@job)
    return render("lamar/closed", status: :gone) unless @window.open?

    result = Portal::SubmitApplication.call(job: @job, params: application_params, channel_code: params[:ch])
    if result.errors.any?
      @errors = result.errors
      @field_errors = result.field_errors
      @cv_dropped = application_params[:cv].present?
      @answers = knockout_params
      load_consent_shown
      @values = application_params.except(:cv, :knockout)
      return render(:form, status: :unprocessable_entity)
    end

    @token = result.token
    @application = result.application
    return render("lamar/not_eligible") if result.knocked_out

    # D60 slice 3-4: on a job whose S2 is in the gate, the technical test follows the submit. The
    # page offers it now or later (within 48 h), and one email carries the status link and the start
    # deadline (TechnicalTests::Notices; sent and recorded like every candidate email).
    @test = TechnicalTests::Status.new(@application)
    @test_mail = TechnicalTests::Notices.application_received(@application, @token) if @test.can_start?
    # Without a test there was no email at all, so a closed tab lost the status link (step 04).
    unless @test.can_start?
      MailDelivery.deliver!(@application, "application_ack") { CandidateMailer.application_ack(@application, @token) }
    end
    render "lamar/sent"
  rescue Portal::SubmitApplication::Closed
    @window = ApplicationWindow.new(@job)
    render "lamar/closed", status: :gone
  rescue Portal::SubmitApplication::ConsentUnverifiable
    @answers = knockout_params
    @values = application_params.except(:cv, :knockout, :consent_token)
    @errors = ["The terms for the use of your data have changed. Please read and agree to the latest terms below."]
    @field_errors = { consent: @errors.first }
    load_consent_shown
    render :form, status: :unprocessable_entity
  end

  private

  def load_job
    @job = Job.find_by(public_code: params[:code]) or render("candidate_status/invalid", status: :not_found)
  end

  # The consent text and retention days shown on this page, and the signed token that records them.
  def load_consent_shown
    @consent = ConsentTemplate.in_force(company: @job.client_company)
    @retention_days = SystemSetting.retention_days(company: @job.client_company)
    @consent_token = Portal::SubmitApplication.sign_consent(@consent, @retention_days) if @consent && @retention_days
  end

  def knockout_params = params.fetch(:knockout, {}).permit!.to_h.slice(*@job.knockout_questions.map { |q| q.id.to_s })

  def application_params
    # expected_salary_min/max (D62 h5) and domicile_city (D54): feature 08, optional, never sent to the AI.
    params.fetch(:lamaran, {}).permit(:name, :email, :phone, :consent, :cv, :consent_token,
                                      :expected_salary_min, :expected_salary_max, :domicile_city).to_h.symbolize_keys
          .merge(knockout: knockout_params)
  end
end
