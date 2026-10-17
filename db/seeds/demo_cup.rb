# Demo data for the AI Builder Cup: one job, "Accounting Supervisor (Cup demo)", with invented
# candidates at every point of the nine steps, so the demo can be walked end to end and the
# Impact summary has numbers. EVERYTHING HERE IS INVENTED (synthetic data only, Cup rule); all text
# is English (owner's rule, 17 Oct 2026). No AI is called: every AI row carries
# DemoScreeningReport::MODEL_ID ("demo-tanpa-ai (data contoh)"). That id is a CODE, not text:
# Impact::DEMO_MODEL matches the exact string so the Impact summary can say its figures include
# invented data; translating it here alone would silently drop that notice.
#
#   A  full journey: gate "Follow AI advice" (Continue) -> Interview 1 -> Interview 2 scored by the user from the link
#      -> salary agreed by the owner -> offer letter sent
#   B  "Do not continue" at the gate with a note -> rejection letter sent
#   C  Interview 2 with the user's link still waiting (open it live in the demo)
#   D, G  gate with the AI recommendation ready, waiting for the HR PIC's choice (choose live)
#   E, F, H, I  as DemoScreeningReport leaves them (test states, knockout-like profiles)
#
# The job, rubric, Excel test and AI screening rows come from DemoScreeningReport; steps 06-09 go
# through the real services (Progression::Choose, InviteInterviewer, Salary.agree) where they call
# no AI. Idempotent: an existing job (by title) is left alone.
require_relative "demo_screening_report"

module DemoCup
  TITLE = "Accounting Supervisor (Cup demo)".freeze
  # Invented Indonesian names (no real person), so letters and pages read naturally in the demo.
  NAMES = { "A" => "Rina Pratiwi", "B" => "Budi Santoso", "C" => "Siti Rahmawati", "D" => "Agus Setiawan",
            "E" => "Dewi Anggraini", "F" => "Joko Prasetyo", "G" => "Maya Kusuma", "H" => "Fajar Nugroho",
            "I" => "Lestari Handayani" }.freeze
  MODEL_ID = DemoScreeningReport::MODEL_ID

  module_function

  def run(company:, hr:, consultant:, reviewer:, owner:, now: Time.current)
    return Job.find_by(title: TITLE) if Job.exists?(title: TITLE)

    start = now - 5.days
    job = DemoScreeningReport.base(TITLE, company:, hr:, consultant:, now: start + 3.days) # gate opens at `start`
    competencies(job)
    stages = %w[S1 S2 S3].to_h { |code| [code.downcase.to_sym, job.stages.find_by!(code:)] }
    test_case = TechnicalTestCase.current_for(job)
    link = nil
    ActiveRecord::Base.transaction do
      DemoScreeningReport::PEOPLE.each_key do |key|
        DemoScreeningReport.applicant(job, key, stages, test_case, consultant:, reviewer:, hr:, now: start + 2.days, name: NAMES.fetch(key))
      end
      at = start + 2.days + 1.hour
      journey_a(job, hr:, owner:, at:)
      journey_b(job, hr:, at:)
      link = journey_c(job, hr:, at:)
      %w[D G].each { |key| recommend(gate(job, key), hr, "lanjut", 72, at:) }
    end
    puts "Demo Cup: #{TITLE} (/apply/#{job.public_code}). Assessor link #{NAMES.fetch("C")} (Interview 2, hiring manager): /score/#{link}" if link
    job
  end

  def competencies(job)
    [["S3", "L4", "Prepares the monthly financial statements", "Statements late with many corrections", "Statements on time with few corrections", "Statements on time, tidy, and used by management",
      "Tell us about the last monthly close you led."],
     ["S3", "I", "Integrity of financial data", "Hides differences", "Reports differences to the supervisor", "Traces, explains, and prevents repeated differences",
      "What do you do when you find a cash difference?"],
     ["S5", "L5", "Coaches accounting staff", "Does the staff's work personally", "Reviews and gives corrections", "Trains staff until errors fall",
      "How do you make a new staff member independent within a month?"]].each_with_index do |(stage, layer, name, a1, a3, a5, q), i|
      job.competencies.create!(position: i + 1, stage_code: stage, layer:, name:, anchor_1: a1, anchor_3: a3, anchor_5: a5, questions: q)
    end
  end

  def application(job, key) = JobApplication.joins(:candidate).find_by!(job:, candidates: { name: NAMES.fetch(key) })
  def stage_of(job, key, code) = application(job, key).participations.joins(:stage).find_by!(stages: { code: })
  def gate(job, key) = stage_of(job, key, "S1")

  # An AI recommendation row as Progression::Recommend would write it, without the call.
  def recommend(participation, actor, advice, score, at:, summary: nil)
    StageRecommendation.create!(
      participation:, requested_by: actor, status: "ready", advice:, ai_score: score, model_id: MODEL_ID,
      prompt_version: Progression::Recommend::PROMPT_VERSION, created_at: at,
      summary: summary || (advice == "lanjut" ? "Sample data: the evidence at this stage is strong enough to proceed." : "Sample data: the evidence at this stage is not yet enough."),
      reasons: { "strengths" => ["Sample data: prepares monthly journals and reconciliations"], "gaps" => ["Sample data: no external audit experience shown yet"],
                 "risks" => [], "change_view" => "Sample data: the result of the next stage." }
    )
  end

  def choose(participation, actor, choice, at:, note: nil)
    Progression::Choose.call(participation:, actor:, choice:, note:, now: at,
                             seen_recommendation_id: StageRecommendation.latest_for(participation)&.id)
  end

  # An interview scorecard as Progression::ScoreInterview writes it, minus the AI call it makes.
  def interview(participation, actor, rating, note, at:)
    Progression.open_stage!(participation.stage, at)
    participation.update!(attendance: "attended")
    ratings = participation.stage.job.competencies.where(stage_code: participation.stage.code).to_h { |c| [c.id.to_s, rating] }
    entry = ScoreEntry.create!(participation:, value: Scoring::StageScore.from_ratings(ratings.values), ratings:, note:,
                               entered_by_id: actor.id, event_at: at, entered_at: at)
    Progression.redecide!(participation, actor, at)
    entry
  end

  def journey_a(job, hr:, owner:, at:)
    recommend(gate(job, "A"), hr, "lanjut", 80, at:)
    choose(gate(job, "A"), hr, "ikut_ai", at: at + 1.hour)
    s3 = stage_of(job, "A", "S3")
    interview(s3, hr, 4, "Sample data: explained the month-end close and reconciliation step by step.", at: at + 1.day)
    recommend(s3, hr, "lanjut", 78, at: at + 1.day + 5.minutes)
    choose(s3, hr, "ikut_ai", at: at + 1.day + 1.hour)
    s5 = stage_of(job, "A", "S5")
    invite, _token = Progression::InviteInterviewer.call(participation: s5, actor: hr, name: "Ms Ratna (Finance Manager, sample data)", now: at + 2.days)
    entry = interview(s5, hr, 5, "Sample data: has trained two new staff members to work independently.", at: at + 2.days + 3.hours)
    invite.update!(score_entry: entry, submitted_at: entry.entered_at)
    UserRecommendation.create!(job_application: s5.job_application, user_name: invite.interviewer_name, pick: "lanjut",
                               note: "Sample data.", entered_by: hr, created_at: entry.entered_at)
    recommend(s5, hr, "lanjut", 84, at: at + 2.days + 3.hours + 2.minutes)
    choose(s5, hr, "ikut_ai", at: at + 2.days + 4.hours)
    application = s5.job_application
    rec = SalaryRecommendation.create!(job_application: application, requested_by: hr, status: "ready", position: 0.6,
                                       amount: Progression::Salary.amount_for(job, 0.6), summary: "Sample data: a strong candidate at every stage.",
                                       factors: ["Sample data: Interview 2 scored 5"], model_id: MODEL_ID,
                                       prompt_version: Progression::Salary::PROMPT_VERSION, created_at: at + 2.days + 5.hours)
    Progression::Salary.agree(application:, actor: owner, amount: rec.amount, note: nil, seen_recommendation_id: rec.id)
    letter(application, hr, "offer", "Job offer: #{job.title}",
           "Dear [Candidate name],\n\nCongratulations: we offer you the position of #{job.title} at #{Progression::Letters.rupiah(rec.amount)} per month.\n\nHR (sample data)",
           at: at + 2.days + 6.hours)
  end

  def journey_b(job, hr:, at:)
    recommend(gate(job, "B"), hr, "tidak_lanjut", 52, at:)
    choose(gate(job, "B"), hr, "ikut_ai", at: at + 2.hours, note: "Sample data: technical test score 58, below the threshold of 60.")
    letter(application(job, "B"), hr, "rejection", "News about your application: #{job.title}",
           "Dear [Candidate name],\n\nThank you for your time. We will not take your application further on this occasion.\n\nHR Team (sample data)",
           at: at + 3.hours)
  end

  def journey_c(job, hr:, at:)
    recommend(gate(job, "C"), hr, "lanjut", 85, at:)
    choose(gate(job, "C"), hr, "lanjut", at: at + 1.hour)
    s3 = stage_of(job, "C", "S3")
    interview(s3, hr, 4, "Sample data: experienced as a manager; confirm they will accept a supervisor position.", at: at + 1.day)
    recommend(s3, hr, "lanjut", 76, at: at + 1.day + 5.minutes)
    choose(s3, hr, "lanjut", at: at + 1.day + 2.hours)
    _invite, token = Progression::InviteInterviewer.call(participation: stage_of(job, "C", "S5"), actor: hr,
                                                         name: "Ms Ratna (Finance Manager, sample data)", now: at + 2.days)
    token
  end

  # A letter already sent: the exact text and its delivery, as Progression::Letters.send! records it.
  def letter(application, actor, kind, subject, body, at:)
    delivery = MailDelivery.create!(job_application: application, kind: "#{kind}_letter", status: "sent", created_at: at)
    CandidateLetter.create!(job_application: application, kind:, status: "sent", subject:, body:, mail_delivery: delivery,
                            actor:, created_at: at)
  end
end
