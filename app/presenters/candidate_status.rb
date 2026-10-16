# What a candidate sees on their status page (screen 11; BP §3.6 B2–B6, principles 3 and 4 of
# the feature plan). Built from this application only, and it exposes no score, rank, threshold
# or other candidate: the view can only print what this object returns.
#
# Outcome per stage appears only once the stage is CLOSED. Builder default (feature record §8):
# a decision taken while the stage is open may still be confirmed or reversed by a person, so a
# candidate never sees a provisional "belum lolos".
class CandidateStatus
  STAGE_LABELS = {
    "S1" => "CV screening", "S2" => "Technical test", "S3" => "Interview 1",
    "S4" => "Psychological test", "S5" => "Interview 2", "RC" => "Reference check"
  }.freeze

  # Reason categories shown with "belum lolos" (Talent Board 2024 via BP §3.6 B2): a category,
  # never a score.
  REASON_CATEGORIES = {
    "knockout" => "An answer to a must-have question did not meet the requirement.",
    "no_show" => "You did not attend the scheduled appointment.",
    "withdrew" => "You withdrew from this stage."
  }.freeze
  DEFAULT_REASON = "The result of this stage did not meet the standard set for this position."

  Step = Data.define(:label, :state, :date_text, :note, :participation, :appointment, :reason, :objection)

  attr_reader :application, :now

  def initialize(application, now: Time.current)
    @application = application
    @now = now
  end

  def job = application.job
  def candidate_name = application.candidate.name
  def withdrawn? = application.consent_withdrawn_at.present?
  # D60: the technical test of a gated job (state :none on every other job).
  def technical_test = @technical_test ||= TechnicalTests::Status.new(application, now:)

  def steps
    @steps ||= begin
      stages = stage_steps
      [received_step] + stages + [offer_step(after_elimination: stages.any? { |s| s.state == :not_passed })]
    end
  end

  # The one line that says what happens next and when ("always a next date").
  def next_line
    step = steps.find { |s| %i[current scheduled].include?(s.state) }
    return "You passed every selection stage. News of a job offer will appear on this page." if step.nil? && awaiting_offer?
    return "Your selection process is complete. Thank you." if step.nil?

    if step.appointment
      "#{step.label} · #{I18n.l(step.appointment.starts_at.in_time_zone, format: :long_wib)}"
    elsif step.date_text
      "#{step.label} · #{step.date_text}"
    else
      "#{step.label} · the date of the next update will appear on this page"
    end
  end

  Summary = Data.define(:text, :tone)

  # One line for staff lists (information-display review D1, 2026-10-10). Built from the same steps
  # the candidate sees, so the staff list and the candidate page cannot disagree; before this the
  # staff list printed job_applications.status, which no decision updates, and showed an eliminated
  # candidate as "Dalam proses".
  def summary
    return Summary.new(text: "Consent withdrawn", tone: "muted") if withdrawn?

    failed = steps.find { |s| s.state == :not_passed }
    return Summary.new(text: "Not passed · #{failed.label.sub(': not passed', '')}", tone: "danger") if failed

    step = steps.find { |s| %i[current scheduled].include?(s.state) }
    return Summary.new(text: "Passed every stage · awaiting an offer", tone: "success") if step.nil? && awaiting_offer?
    return Summary.new(text: "Done", tone: "success") if step.nil?

    if step.appointment
      when_text = I18n.l(step.appointment.starts_at.in_time_zone, format: :short_wib)
      Summary.new(text: "#{step.label} · scheduled #{when_text}", tone: "info")
    else
      Summary.new(text: "#{step.label} · in progress", tone: "info")
    end
  end

  # Every stage passed, no "belum lolos", and no offer yet: the candidate waits for one.
  def awaiting_offer? = steps.none? { |s| s.state == :not_passed } && steps.last.state == :waiting

  def latest_offer = @latest_offer ||= OfferDocument.latest_for(application)
  def offer_visible? = latest_offer.present?
  def accepted_offer = application.offer_documents.find_by(response: "accepted")
  def upcoming_consent = ConsentTemplate.upcoming(now, company: job.client_company)

  private

  def received_step
    Step.new(label: "Application received", state: :done, date_text: date(application.created_at), note: nil,
             participation: nil, appointment: nil, reason: nil, objection: nil)
  end

  def stage_steps
    eliminated = false
    job.stages.order(:code).flat_map do |stage|
      # D60: S1 and S2 in the gate "Seleksi CV dan Tes Teknis" are shown as the technical test
      # (its four states) followed by ONE gate outcome, at S1's place in the order.
      next [] if stage.gated? && stage.code != "S1"

      participation = application.participations.find { |p| p.stage_id == stage.id }
      steps = stage.gated? ? gate_steps(eliminated) : [stage_step(stage, participation, eliminated)]
      eliminated ||= steps.any? { |step| step.state == :not_passed }
      steps
    end
  end

  GATE_LABEL = Stage::GATES.fetch("screening")
  TEST_LABEL = "Technical test"

  # Plan §e: "Tes teknis" with Belum dimulai / Sedang dikerjakan / Jawaban terkirim / Tidak
  # dikerjakan, then the gate outcome, which appears only once BOTH stages are closed (D38 Q6a) and
  # carries a reason category, never a score (D28). A missed test reads "Tidak dikerjakan" on its
  # own row; it is not shown as "belum lolos" before the gate closes, because only the closed gate
  # decides.
  def gate_steps(after_elimination)
    blank = { participation: nil, appointment: nil, reason: nil, objection: nil, note: nil, date_text: nil }
    if after_elimination
      return [Step.new(label: TEST_LABEL, state: :skipped, **blank), Step.new(label: GATE_LABEL, state: :skipped, **blank)]
    end

    test = test_step(blank)
    [test, gate_step(blank, test_current: test.state == :current)]
  end

  def test_step(blank)
    test = technical_test
    state, text =
      case test.state
      when :not_started then [:current, "Not started, start by #{date_at(test.start_by)}"]
      when :running then [:current, "In progress, #{(test.remaining_seconds / 60.0).ceil} minutes left (ends #{clock(test.due_at)})"]
      when :sent then [:done, "Answer sent #{I18n.l(test.answered_at.in_time_zone, format: :long_wib)}"]
      when :expired then [:missed, "Not taken"]
      else [:skipped, nil]
      end
    Step.new(label: TEST_LABEL, state:, **blank.merge(date_text: text, participation: test.participation))
  end

  # While the test still waits for the candidate, the gate waits behind it; once the test is sent
  # or missed, the gate is the current step, so "Berikutnya" never says the process is finished
  # while the gate is still open (found on the 2026-10-10 screenshots).
  def gate_step(blank, test_current:)
    outcome = TechnicalTests::GateOutcome.for(application)
    # Final for this candidate once the gate closes, or once the HR PIC's choice is recorded (AI
    # Builder Cup step 06: one choice per step, never changed; its decisions match it).
    chosen = application.participations.joins(:stage).find_by(stages: { code: "S1" })&.progression_choice.present?
    final = outcome && (outcome.closed? || chosen)
    if final && outcome.passed?
      return Step.new(label: "#{GATE_LABEL}: passed", state: :done, **blank.merge(date_text: date(outcome.decided_at)))
    end
    if final && outcome.not_passed?
      eliminating = outcome.eliminating_participation
      return Step.new(label: "#{GATE_LABEL}: not passed", state: :not_passed,
                      **blank.merge(date_text: date(outcome.decided_at), reason: outcome.reason, participation: eliminating,
                                    objection: eliminating.objections.order(:received_at).last))
    end

    s1 = job.stages.find_by(code: "S1")
    due = s1&.results_due_on && "result by #{I18n.l(s1.results_due_on, format: :long)} at the latest"
    Step.new(label: GATE_LABEL, state: test_current ? :waiting : :current,
             **blank.merge(date_text: due || "The result appears once this stage is complete"))
  end

  # "12 October 2026 at 17:32 WIB" (WIB, hours:minutes, as en.yml formats it).
  def date_at(time) = "#{I18n.l(time.in_time_zone.to_date, format: :long)} at #{clock(time)}"
  def clock(time) = I18n.l(time.in_time_zone, format: "%H:%M WIB")

  def stage_step(stage, participation, after_elimination)
    label = STAGE_LABELS.fetch(stage.code)
    blank = { participation:, appointment: nil, reason: nil, objection: nil, note: nil, date_text: nil }
    return Step.new(label:, state: :skipped, **blank) if after_elimination
    return Step.new(label:, state: :waiting, **blank) if participation.nil?

    appointment = participation.appointment
    decision = participation.current_decision
    # Final once the stage closes, or once the HR PIC's choice for this candidate is recorded (step 06).
    if (stage.status == "closed" || participation.progression_choice) && decision
      if decision.outcome == "pass"
        return Step.new(label: "#{label}: passed", state: :done, **blank.merge(date_text: date(decision.decided_at)))
      end

      return Step.new(label: "#{label}: not passed", state: :not_passed,
                      **blank.merge(date_text: date(decision.decided_at),
                                    reason: REASON_CATEGORIES.fetch(decision.reason_code, DEFAULT_REASON),
                                    objection: participation.objections.order(:received_at).last))
    end

    due = stage.results_due_on && "result by #{I18n.l(stage.results_due_on, format: :long)} at the latest"
    Step.new(label:, state: appointment ? :scheduled : :current, **blank.merge(appointment:, date_text: due))
  end

  # After a "belum lolos" the offer step is greyed out like the later stages, so the page never
  # suggests an eliminated candidate is still waiting for an offer (screenshot 2026-10-10).
  def offer_step(after_elimination:)
    blank = { participation: nil, appointment: nil, reason: nil, objection: nil, note: nil, date_text: nil }
    return Step.new(label: "Job offer", state: :skipped, **blank) if after_elimination && latest_offer.nil?
    return Step.new(label: "Job offer", state: :waiting, **blank) unless latest_offer

    state = latest_offer.accepted? ? :done : :current
    Step.new(label: "Job offer", state:, **blank.merge(date_text: date(latest_offer.created_at)))
  end

  def date(time) = time && I18n.l(time.in_time_zone.to_date, format: :long)
end
