# Demo data for feature 07 slices 3-5, the technical test in the apply flow (D60; GlassBox Team D52, 18:0x:
# "build a seeder for all the sample data"). All text is English (owner's rule, 17 Oct 2026).
#
# EVERYTHING HERE IS INVENTED: two jobs, the candidates ("Test Participant 01" ...), their e-mail
# addresses (@contoh.example, a reserved invented domain kept as a name), the case and answer
# workbooks. No real candidate data.
#
# One row per technical-test state, so every screen has something to show:
#   OPEN gate   01 not started, inside 48 h (the 24-hour reminder recorded)
#               02 started, time left
#               03 answer sent, waiting for the reviewer
#               04 scored, pass (rubric 5/4/4 on weights 50/30/20 = 87.5, threshold 60)
#               05 scored, fail (rubric 2/2/3 = 30.0)
#               06 not started within 48 h -> no_show (rule 5)
#               07 started, no answer by due_at + 2 min -> no_show
#   CLOSED gate 08 S1 pass + S2 scored pass   -> gate passed
#               09 S1 eliminated + S2 answered -> gate_eliminated at close (never scored, B-1)
#               10 S1 pass + S2 not started    -> no_show; gate failed
#             then Gates::Close, which sends one gate-outcome notice per applicant.
# Notices recorded where the rules allow them: application_received at submit, test_reminder at
# 24 h, test_receipt on every answer, gate_outcome at close (MailDelivery rows, dev mail delivery).
#
# The clock: every time is relative to the moment the seed runs. "Started, time left" (02) is only
# true for 25 minutes after seeding; afterwards the pages show it as expired, which is correct.
#
# Written through the real services (TestCases::SaveVersion/Approve, Gates::Open/Close,
# TechnicalTests::Start/SubmitAnswer/ScoreAnswer/Expire/Notices), so a seed that breaks a rule fails
# loudly. The applications are inserted directly (as the screening-report seed does), because Lamar
# refuses a submit time before the consent text in force on a fresh development database.
# Idempotent: a job is created once (by title); applicants are added only to an empty S1.
require_relative "demo_test_cases"

module DemoTechnicalTest
  TITLES = {
    open: "Warehouse Admin Staff (Technical test demo, gate open)",
    closed: "Warehouse Admin Staff (Technical test demo, gate closed)"
  }.freeze
  PDF = "%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n".freeze

  module_function

  def run(company:, hr:, consultant:, reviewer:, now: Time.current)
    TITLES.map do |state, title|
      # Base outside any transaction: the test-case freeze trigger is deferred, so approving and
      # starting a version inside one transaction fails at commit (see demo_screening_report.rb).
      job = Job.find_by(title:) || base(title, company:, hr:, consultant:, now:)
      raise "#{title}: no approved test version; remove the half-built job by hand" unless TechnicalTestCase.current_for(job)

      s1 = job.stages.find_by!(code: "S1")
      next job if s1.participations.exists?

      ActiveRecord::Base.transaction { state == :open ? open_job(job, reviewer:, now:) : closed_job(job, reviewer:, now:) }
      job
    end
  end

  def base(title, company:, hr:, consultant:, now:)
    job = Job.create!(title:, golongan: 3, client_company: company, location: "Cikarang", consultant:, package: 3,
                      brief_status: "complete", brief_completed_at: now - 5.days, ad_approved_at: now - 4.days, ad_approved_by_id: hr.id)
    [["Record goods in and out", "Accurate stock cards", 50], ["Monthly stock count", "Stock differences explained", 30],
     ["Prepare the weekly stock report", "Report on time", 20]].each_with_index do |(d, o, s), i|
      job.activities.create!(position: i + 1, description: d, output: o, share_percent: s)
    end
    job.stages.create!(code: "S1", score_source: "ai", weight: 10, threshold: 60, gate: "screening")
    job.stages.create!(code: "S2", score_source: "manual_or_import", weight: 20, threshold: 60, gate: "screening")
    job.stages.create!(code: "S5", score_source: "scorecard", weight: 70, threshold: 70)
    approved_test(job, consultant:, hr:)
    Gates::Open.call(stage: job.stages.find_by!(code: "S1"), now: now - 3.days)
    job
  end

  def approved_test(job, consultant:, hr:)
    rows = [["Code", "Item name", "System stock", "Physical stock"], ["BRG-01", "Wooden pallet", 120, 112], ["BRG-02", "Stretch film", 40, 44]]
    activities = job.activities.order(:position).to_a
    params = { instructions: "The Data sheet holds one month of stock cards with several differences (invented data). Find the differences and write the corrections on the Answers sheet.",
               time_limit_minutes: "35", answer_types_submitted: "1", answer_types: %w[xlsx],
               case_file: DemoTestCases::SeedUpload.new(DemoTestCases.workbook("Stock card case (invented data).", rows), "stock-case.xlsx"),
               criteria: [[0, "Finds the stock differences", 50], [1, "Correct corrections", 30], [2, "Explanation for the supervisor", 20]]
                 .each_with_index.to_h do |(a, name, w), i|
                 [i.to_s, { activity_id: activities[a].id.to_s, name:, weight: w.to_s, anchor_1: "No difference found",
                            anchor_3: "Some differences found", anchor_5: "Every difference found and explained" }]
               end }
    saved = TestCases::SaveVersion.call(job:, actor: consultant, params:)
    raise "demo test refused: #{saved.errors.join(' | ')}" unless saved.ok?

    approved = TestCases::Approve.call(test_case: saved.test_case, actor: hr)
    raise "demo test not approved: #{approved.errors.join(' | ')}" unless approved.ok?
  end

  def open_job(job, reviewer:, now:)
    applicant(job, 1, now - 30.hours).then { |a| TechnicalTests::Notices.reminder(a, now:) }
    applicant(job, 2, now - 2.hours).then { |a| start(a, now - 10.minutes) }
    applicant(job, 3, now - 6.hours).then { |a| answer(a, now - 5.hours) }
    applicant(job, 4, now - 8.hours).then { |a| score(answer(a, now - 7.hours), [5, 4, 4], reviewer:, now: now - 1.hour) }
    applicant(job, 5, now - 9.hours).then { |a| score(answer(a, now - 8.hours), [2, 2, 3], reviewer:, now: now - 1.hour) }
    applicant(job, 6, now - 50.hours).then { |a| TechnicalTests::Expire.call(a, now:) }
    applicant(job, 7, now - 20.hours).then do |a|
      start(a, now - 19.hours)
      TechnicalTests::Expire.call(a, now:)
    end
  end

  def closed_job(job, reviewer:, now:)
    passed = applicant(job, 8, now - 10.hours)
    s1_decision(passed, 80, reviewer:)
    score(answer(passed, now - 9.hours), [5, 5, 4], reviewer:, now: now - 2.hours)
    out = applicant(job, 9, now - 10.hours)
    s1_decision(out, 40, reviewer:)
    answer(out, now - 9.hours)
    missed = applicant(job, 10, now - 50.hours)
    s1_decision(missed, 75, reviewer:)
    TechnicalTests::Expire.call(missed, now:)
    Gates::Close.call(stage: job.stages.find_by!(code: "S1"), now:)
  end

  # An application as Lamar stores it (both gate stages entered, consent recorded, a status link),
  # then the submit notice exactly as Lamar sends it.
  def applicant(job, number, applied)
    label = format("%02d", number)
    candidate = Candidate.create!(name: "Test Participant #{label}", email: "test.participant.#{label}.#{job.id}@contoh.example",
                                  phone: format("0812-0000-%04d", job.id * 100 + number))
    consent = ConsentTemplate.in_force or raise "no consent text in force: publish one on System settings first"
    application = JobApplication.create!(job:, candidate:, consent_at: applied, consent_template: consent,
                                         consent_retention_days: SystemSetting.retention_days || 30, created_at: applied)
    application.cv.attach(io: StringIO.new(PDF), filename: "sample-cv.pdf", content_type: "application/pdf")
    job.stages.where(gate: "screening").order(:code).each do |stage|
      Participation.create!(job_application: application, stage:, attendance: "pending")
    end
    _link, token = OneTimeLink.issue!(subject: application, purpose: "candidate_status")
    TechnicalTests::Notices.application_received(application, token)
    application
  end

  def start(application, at) = TechnicalTests::Start.call(application:, now: at)

  def answer(application, started)
    start(application, started)
    file = DemoTestCases::SeedUpload.new(DemoTestCases.workbook("Answer (invented data).", [["Code", "Correction"], ["BRG-01", -8], ["BRG-02", 4]]),
                                         "answer.xlsx")
    attempt = TechnicalTests::SubmitAnswer.call(application:, file:, now: started + 28.minutes)
    TechnicalTests::Notices.receipt(application)
    attempt
  end

  def score(attempt, ratings, reviewer:, now:)
    by_id = attempt.test_case.criteria.zip(ratings).to_h { |criterion, value| [criterion.id.to_s, value.to_s] }
    TechnicalTests::ScoreAnswer.call(attempt:, reviewer:, ratings: by_id, note: "Sample data: rubric scoring.", now:)
  end

  # S1 decided by a named person (a manual decision with a note), not by an invented AI score: an
  # AI score row must name its model and prompt (CHECK score_entries_ai_actor_names_model), and this
  # seed calls no model. pass for value >= 60 (the S1 line), eliminate below it.
  def s1_decision(application, value, reviewer:)
    s1 = application.participations.joins(:stage).find_by!(stages: { code: "S1" })
    Decision.create!(participation: s1, outcome: value >= s1.stage.threshold ? "pass" : "eliminate", basis: "manual",
                     reason_code: "demo_manual", note: "Sample data: CV screening decision by the reviewer (score #{value}).",
                     decided_by_id: reviewer.id, decided_at: Time.current)
  end
end
