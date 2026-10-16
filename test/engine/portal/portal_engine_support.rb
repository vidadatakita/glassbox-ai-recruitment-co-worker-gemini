# Shared helpers for the feature-02 test engine (Portal Pelamar). Every name and address is
# invented. Written by the test engine, 2026-10-10; the builder's helpers (PortalFactory,
# ScoringFactory) are reused, never changed.
module PortalEngineSupport
  # House hard rules (blueprint §5.3), asserted on rendered HTML: no nested
  # form, no disabled submit, no data-disable-with / turbo-submits-with, never "Terapkan", the
  # view icon is never fa-eye, and every submit button carries a name and a value so the
  # pressed button reaches the controller.
  def assert_engine_house_rules(html, where)
    doc = Nokogiri::HTML(html)
    doc.css("form").each { |form| assert_empty form.css("form"), "nested form on #{where}" }
    assert_empty doc.css("button[disabled], input[type=submit][disabled]"), "disabled submit on #{where}"
    assert_empty doc.css("[data-disable-with], [data-turbo-submits-with]"), "a button is disabled or relabelled on submit on #{where}"
    refute_match(/terapkan/i, html, "the word Terapkan on #{where}")
    refute_match(/fa-eye\b/, html, "fa-eye on #{where} (house rule: fa-plus)")
    doc.css("form").each do |form|
      # The sign-out button (Rails generator, form to /session) dispatches on nothing.
      next if form["action"].to_s.end_with?("/session")

      form.css("button[type=submit], button:not([type]), input[type=submit]").each do |button|
        assert button["name"].present? && button["value"].present?,
               "a submit button without name/value on #{where}: #{button.to_html[0, 120]}"
      end
    end
    doc
  end

  # Serialises a rendered form the way a browser does when `button` is pressed: every
  # successful control plus the pressed button's name and value. Returns [method, action, params].
  def browser_submission(form, button, fill = {})
    params = {}
    form.css("input, textarea, select").each do |field|
      name = field["name"]
      next if name.blank? || field["disabled"]
      type = field["type"].to_s.downcase
      next if %w[submit button file].include?(type)
      next if %w[checkbox radio].include?(type) && !field.key?("checked")

      value = field.name == "textarea" ? field.text : field["value"].to_s
      value = field.css("option[selected]").first&.[]("value").to_s if field.name == "select"
      params[name] = value
    end
    params.merge!(fill.transform_keys(&:to_s))
    params[button["name"]] = button["value"] if button["name"].present?
    method = (params.delete("_method") || form["method"] || "get").downcase
    [method, form["action"], params]
  end

  # Presses the button whose value is `button_value` on the current page, through a real
  # request, and returns the params the controller received.
  def press(button_value, fill = {})
    doc = Nokogiri::HTML(response.body)
    button = doc.css("form button[value='#{button_value}'], form input[type=submit][value='#{button_value}']").first
    assert button, "no button '#{button_value}' on #{request.path}"
    form = button.ancestors("form").first
    method, action, params = browser_submission(form, button, fill)
    received = nil
    callback = ->(*, payload) { received = payload[:params] }
    ActiveSupport::Notifications.subscribed(callback, "process_action.action_controller") do
      send(method, action, params:)
    end
    received
  end

  def stage_of(job, code) = job.stages.find_by!(code:)

  # Opens the stage if needed, records attendance, a score and a decision, and optionally closes.
  def decide_stage!(application, code, outcome:, score: 80, close: true, reason_code: nil)
    stage = stage_of(application.job, code)
    Stages::Open.call(stage:) if stage.status == "draft"
    # D63 strict entry: a later-stage participation exists only through a person's Lanjut on the
    # previous choice stage, so the fixture enters the stage the way the product does.
    participation = application.participations.find_by(stage:) ||
                    enter_stage_by_choice!(application, stage, attendance: "attended")
    participation.update!(attendance: "attended")
    add_score(participation, score)
    reason_code ||= outcome == "pass" ? "at_or_above_threshold" : "below_threshold"
    decide!(participation, outcome:, reason_code:)
    Stages::Close.call(stage: stage.reload) if close
    participation
  end

  def upload_offer!(application, valid_until: 20.days.from_now.to_date)
    Portal::UploadOffer.call(application:, actor: staff_user("consultant"),
                             params: { pdf: pdf_upload, start_at: "2026-11-17 08:00",
                                       valid_until: valid_until.iso8601, day_one_notes: "Bawa KTP asli." })
  end

  # An application that passed S1 and S5 (both closed), ready for an offer.
  def offer_ready!(job, **submit_overrides)
    application, token = submit!(job, **submit_overrides)
    decide_stage!(application, "S1", outcome: "pass", close: false)
    [application, token]
  end

  def close_s1_and_pass_s5!(job, applications)
    s1 = stage_of(job, "S1")
    Stages::Close.call(stage: s1) if s1.status == "open"
    applications.each { |app| decide_stage!(app, "S5", outcome: "pass", close: false) }
    Stages::Close.call(stage: stage_of(job, "S5"))
  end

  # D35 contract (2026-10-10): step 2 carries a signed lamaran[consent_token] recording the
  # version and retention days SHOWN. A browser-shaped submission takes it from the step-2 page.
  def step2_token(job)
    post lamar_check_path(job.public_code), params: { knockout: answers_for(job) }
    assert_response :success, "step 2 did not render (window state #{ApplicationWindow.new(job).state})"
    token = Nokogiri::HTML(response.body).at_css("input[name='lamaran[consent_token]']")&.[]("value")
    assert token.present?, "step 2 carries no consent token"
    token
  end

  def shown_by(token) = Portal::SubmitApplication.consent_verifier.verified(token)

  # A complete consent text (no [PLACEHOLDER], D38) with one distinctive purpose line.
  def complete_consent(purpose: "Tujuan uji lengkap.", effective_from: 1.day.from_now)
    PortalFactory::COMPLETE_CONSENT.merge(purpose:, effective_from: effective_from.iso8601)
  end

  def last_code_for(email)
    mail = ActionMailer::Base.deliveries.reverse.find { |m| m.to == [email] && m.subject.include?("code to open") }
    mail&.body.to_s[/\b\d{6}\b/]
  end
end
