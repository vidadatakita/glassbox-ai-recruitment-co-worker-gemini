require "test_helper"

# Independent test pass (17 Oct 2026) on the three steppers: HiringProgress (vacancy page), BriefProgress
# (brief page) and ApplicationProgress (applicant page), drawn by staff/jobs/_hiring_progress.
#
# Oracles: a step is "done" only when the record it reads exists; the time shown is that record's time
# (displayed in Jakarta local time, WIB, +07:00); the person shown is the person on THAT record, never
# the actor of a different record; the per-step applicant counts tie out to the rows counted here
# independently (Ruby iteration over the records, not the presenter's SQL).
#
# Selection: the counts are tied out on the seeded demo vacancies (every vacancy the seed writes). The
# interview-done rule and the brief actor are fixtured directly. Not covered: the approval chain's
# "Scores the technical test" link, the reopen window action.
class PolishProgressSteppersPassTest < ActionDispatch::IntegrationTest
  include TechnicalTestFactory
  include ScoringFactory
  include GateFactory

  def step(progress, key) = progress.steps.find { |s| s.key == key }

  # --- HiringProgress: who is shown for the brief -------------------------------------------------

  # The Brief step shows the brief's completion time. The person beside it must be the person who
  # completed it (the "complete" history row), as BriefProgress#completion does. A later history row of
  # another step (the ad approval the portal open records, step "ad") is a different record.
  test "the Brief step names the person who completed the brief, not the author of a later history row" do
    job = briefed_job(golongan: 3, package: 3)
    completer = job.brief_changes.where(step: "complete").order(:id).last.actor
    assert_equal staff_user("hr_pic"), completer, "fixture: the brief was completed by the HR Admin hr_pic"

    opener = staff_user("superadmin")
    set_retention
    publish_consent
    Portal::WindowChange.open!(job:, actor: opener, closes_at: nil, quota: nil, now: 2.minutes.from_now)
    assert job.brief_changes.where(step: "ad", actor: opener).exists?, "fixture: the open wrote an ad history row"

    brief = step(HiringProgress.new(job.reload), :brief)
    assert brief.done?
    assert_equal completer, brief.actor, "the Brief step is attributed to #{brief.actor&.name.inspect}, who did not complete it"
  end

  # --- HiringProgress: interviews done vs counted ---------------------------------------------------

  # The Interviews step counts applicants with an interview score (S3/S5 score entries) but is "done"
  # only when an interviewer link was submitted. An interview scored in the app by the HR Admin
  # (Progression::ScoreInterview writes a ScoreEntry, no InterviewerInvite) is counted and not done.
  # The fixture writes the same ScoreEntry row ScoreInterview writes.
  test "an interview score recorded without an interviewer link: the step is counted AND shown done" do
    job, s1, s2 = gated_job
    s5 = job.stages.find_by!(code: "S5")
    application = JobApplication.create!(job:)
    Participation.create!(job_application: application, stage: s1, attendance: "attended")
    Participation.create!(job_application: application, stage: s2, attendance: "attended")
    interview = Participation.create!(job_application: application, stage: s5, attendance: "attended")
    add_score(interview, 80)

    progress = HiringProgress.new(job)
    interviews = step(progress, :interview)
    assert_equal 1, interviews.count, "control: the scored interview is counted"
    assert interviews.done?, "the Interviews step shows '1 applicant' yet stays 'Waiting'"
  end

  # --- HiringProgress: counts tie out ----------------------------------------------------------------

  test "every per-step count on every seeded vacancy equals the rows counted here; a done step has its record" do
    saved = %i[enabled? review_before_ai?].to_h { |name| [name, Screening::Config.method(name)] }
    with_env("DEMO_MODE" => "1", "LEGACY_DEMO_SEEDS" => nil) { capture_io { Rails.application.load_seed } }
    jobs = Job.all.to_a
    assert_operator jobs.size, :>=, 1, "fixture: the seed wrote vacancies"
    nonzero = Hash.new(0)

    jobs.each do |job|
      apps = job.job_applications.includes(participations: %i[stage score_entries screening_results]).to_a
      parts = apps.flat_map(&:participations)
      scored = ->(codes) { apps.count { |a| a.participations.any? { |p| codes.include?(p.stage.code) && p.score_entries.any? } } }
      expected = {
        open: apps.count { |a| a.candidate_id.present? },
        release: parts.count { |p| p.screening_results.any? },
        test: scored.call(%w[S2]),
        decision: parts.count { |p| p.stage.code == "S1" && ProgressionChoice.exists?(participation_id: p.id) },
        interview: scored.call(%w[S3 S5]),
        salary: apps.count { |a| SalaryAgreement.exists?(job_application_id: a.id) }
      }
      progress = HiringProgress.new(job)
      expected.each do |key, count|
        shown = step(progress, key)
        next if shown.nil? # the technical test step exists only where the package has one

        assert_equal count, shown.count, "#{job.title}: #{key}"
        nonzero[key] += 1 if count.positive?
      end
      progress.steps.select(&:done?).each do |s|
        assert s.at.is_a?(ActiveSupport::TimeWithZone) || s.at.is_a?(Time), "#{job.title}: #{s.key} done without a time"
        assert(s.actor.nil? || s.actor.is_a?(User) || s.actor.is_a?(String), "#{job.title}: #{s.key} actor #{s.actor.class}")
      end
      first_pending = progress.steps.index { |s| !s.done? }
      assert_equal progress.current_key, first_pending && progress.steps[first_pending].key
    end
    # Control: the tie-out compared real, non-zero counts, not a page of zeros.
    assert_operator nonzero[:open], :>=, 1, "no seeded vacancy had applicants: the tie-out checked zeros only"
    assert_operator nonzero[:release], :>=, 1, "no seeded vacancy had screening results"
  ensure
    saved&.each { |name, original| Screening::Config.singleton_class.define_method(name, original) }
  end

  # An application without a candidate (an abandoned start of the apply form) is not an applicant.
  test "the open count leaves out applications without a candidate" do
    job, = gated_job
    JobApplication.create!(job:)
    assert_equal 0, step(HiringProgress.new(job), :open).count
  end

  # --- The stepper on the vacancy page: time in WIB, the actor from the record ---------------------

  test "the vacancy page prints the portal-open time in WIB and the opener's name from the window event" do
    job = briefed_job(golongan: 3, package: 3)
    # 20:15 UTC on 17 Oct is 03:15 on 18 Oct in Jakarta: the date itself changes, so a UTC display fails.
    opened_at = Time.utc(2026, 10, 17, 20, 15)
    travel_to(opened_at) { open_portal(job, now: opened_at) }
    sign_in_as staff_user("superadmin")
    get staff_job_path(job)
    assert_response :success
    doc = Nokogiri::HTML(response.body)
    item = doc.css("#hiring-progress li.hiring-progress__step").find { |li| li.at_css(".hiring-progress__label")&.text == "Portal open" }
    assert item, "the Portal open step is drawn"
    assert_includes item["class"], "hiring-progress__step--done"
    assert_equal "18/10/2026 03:15", item.at_css(".hiring-progress__when").text.strip
    assert_equal staff_user("hr_pic").name, item.at_css(".hiring-progress__who").text.strip
    assert_empty doc.css("#hiring-progress form"), "the stepper is display only"
  end

  # --- ApplicationProgress: a later stage's time and actor come from one record --------------------

  # The step shows the decision's time when there is one, but the person who entered the score. When
  # the score was entered by one person and a manual decision taken later by another, the time is the
  # decider's and the name is the scorer's: a pair no record holds.
  #
  # Rule change, 17 Oct 2026 (Vida, applicant 29): an interview is its own step, so it is done only when
  # its step decision (ProgressionChoice) is made; a score and a stage decision alone leave it open,
  # because the salary card opens only after that choice. The pairing rule is unchanged: once done, the
  # time and the person both come from the step decision.
  test "a later stage step pairs its time and its actor from the same record" do
    job, s1, s2 = gated_job
    s5 = job.stages.find_by!(code: "S5")
    s5.update_columns(status: "open", opened_at: 2.days.ago)
    scorer = staff_user("hr_pic")
    decider = staff_user("consultant")
    application = JobApplication.create!(job:)
    Participation.create!(job_application: application, stage: s1, attendance: "attended")
    Participation.create!(job_application: application, stage: s2, attendance: "attended")
    interview = Participation.create!(job_application: application, stage: s5, attendance: "attended")
    entered_at = 2.hours.ago.change(usec: 0)
    ScoreEntry.create!(participation: interview, value: 50, entered_by_id: scorer.id, event_at: entered_at, entered_at:)
    decided_at = 1.hour.ago.change(usec: 0)
    Decision.create!(participation: interview, outcome: "pass", basis: "manual", reason_code: "manual", note: "Strong case study",
                     decided_by_id: decider.id, decided_at:)

    refute step(ApplicationProgress.new(application.reload), :stage_S5).done?,
           "a score and a stage decision without the step decision do not finish the interview step"

    chooser = staff_user("hr_admin")
    chosen_at = 30.minutes.ago.change(usec: 0)
    ProgressionChoice.create!(participation: interview, choice: "lanjut", direction: "lanjut", actor: chooser, created_at: chosen_at)
    shown = step(ApplicationProgress.new(application.reload), :stage_S5)
    pair = [shown.at.to_i, shown.actor]
    assert_equal [chosen_at.to_i, chooser], pair, "time #{shown.at} is paired with #{shown.actor.try(:name).inspect}"
  end

  # --- BriefProgress: no invented name for a brief written outside the wizard ---------------------

  test "a brief with no history for a step shows 'Recorded', never a person" do
    job = briefed_job(golongan: 3, package: 3)
    progress = BriefProgress.new(job)
    progress.steps.select(&:done?).each do |s|
      assert(s.actor.is_a?(User) || s.actor == "Recorded", "#{s.key}: #{s.actor.inspect}")
      next unless s.actor.is_a?(User)

      recorded = job.brief_changes.where(actor: s.actor).exists?
      assert recorded, "#{s.key}: #{s.actor.name} has no history row on this brief"
    end
  end
end
