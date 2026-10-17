# Demo data for feature 09, the check before AI (D51 B; D52 "build a seeder for all the sample
# data"). All text is English (owner's rule, 17 Oct 2026).
#
# EVERYTHING HERE IS INVENTED: the job, the five candidates ("Release Applicant A" ... "E"),
# their CV texts, employers and dates. No AI is called: development has no API key, and the one
# released text fails visibly with "API key not configured" when the job tries to send it, exactly
# as production would without a key.
#
# One job, five CVs, one per state the release screen shows:
#   A  waiting for the reviewer, clean text (no residual finding)
#   B  waiting for the reviewer WITH a residual finding (a "Place, date" birth date inside the
#      experience section) and protected-word hints (marital status, religion); the release is
#      refused until the line is cut
#   C  no evidence section -> needs a manual check: "No experience/education section found"
#   D  released by the reviewer (who, when, SHA-256 shown); the send then waits for the API key
#   E  "Not sent — decide manually", with the reviewer's note
#
# CV wording is chosen against the detectors, so do not reword it casually:
# - Headings are the English ones Screening::CvSections and Redactor::EVIDENCE_HEADING accept
#   (WORK EXPERIENCE, EDUCATION, SKILLS); a heading they do not know drops the section.
# - B's birth line has no "born"/"dob"/"age" word: the redactor removes those lines, and the
#   residual finding this state exists to show would then never appear.
# - The hints use "married" and "hijab": the redactor leaves those inside evidence sections (F-27)
#   and Screening::ReleaseHighlights marks them. Its family and worship lists are Indonesian only,
#   and "mosque" is removed everywhere (Redactor::RELIGION_EN), so English family or worship words
#   would show NO hint.
# - No CV word repeats the candidate's name words ("Release", "Applicant"): the redactor removes
#   them everywhere.
#
# Everything runs through the real code: the participation callback queues the screening job,
# which runs INLINE here (only for this seed) so Screening::ReleaseGate prepares each text; D is
# released through an append-only AiReleaseAction the database checks (reviewer, not the job's
# consultant, digest = the version's own); E through AiReleases::Decline.
# Idempotent: when the job already exists (by title) nothing is written.
module DemoAiRelease
  TITLE = "Warehouse Staff (Check before AI demo)".freeze

  EVIDENCE = <<~CV.freeze
    WORK EXPERIENCE
    2018 - 2025 Warehouse Admin at PT Sinar Gudang Lestari, Cikarang
    Managed stock of 900 SKUs with a WMS application and monthly stock counts
    EDUCATION
    D3 Logistics Management, Politeknik Swadaya Bekasi, graduated 2017
    SKILLS
    Advanced Microsoft Excel (VLOOKUP, pivot table)
    Holds a SIM C motorcycle licence and is willing to work shifts
  CV

  CVS = {
    "A" => "Release Applicant A\nPhone 0812-0000-1101\n#{EVIDENCE}",
    "B" => "Release Applicant B\n#{EVIDENCE.sub('Managed stock', "Bandung, 01-02-1990\nAs a married mother of two I wear the hijab\nManaged stock")}",
    "C" => "Release Applicant C\nI am hard-working, honest and ready to work shifts at any warehouse.\nI helped in a family business for five years.",
    "D" => "Release Applicant D\n#{EVIDENCE.sub('900 SKUs', '1,500 SKUs')}",
    "E" => "Release Applicant E\n#{EVIDENCE.sub('Advanced Microsoft Excel', 'Married, a wife and mother, skilled in advanced Microsoft Excel')}"
  }.freeze

  module_function

  def run(company:, consultant:, reviewer:)
    existing = Job.find_by(title: TITLE)
    return existing if existing

    job = nil
    with_inline_screening do
      ActiveRecord::Base.transaction { job = build_job(company:, consultant:) }
      people = CVS.to_h { |key, cv| [key, apply!(job, key, cv)] }
      release!(people.fetch("D"), reviewer)
      AiReleases::Decline.call(release: AiRelease.latest_for(people.fetch("E")), user: reviewer,
                               note: "Sample data: the sentence about marriage and family is in the skills section; decided manually.")
    end
    job
  end

  def build_job(company:, consultant:)
    job = Job.create!(title: TITLE, golongan: 2, client_company: company, location: "Cikarang", salary_min: 5_200_000,
                      salary_max: 6_200_000, consultant:)
    [["wajib", "Education at least D3", "D3 or S1 diploma in the CV", nil],
     ["wajib", "Willing to work shifts", "States willingness to work shifts", nil],
     ["sebaiknya", "Warehouse admin experience", "Work history in a warehouse", 60],
     ["sebaiknya", "Skilled in Microsoft Excel", "Excel skill mentioned", 40],
     ["nilai_tambah", "Holds a SIM C licence", "SIM C mentioned", nil]].each_with_index do |(tier, text, evidence, weight), i|
      job.requirements.create!(tier:, text:, cv_evidence: evidence, weight:, position: i + 1)
    end
    job.stages.create!(code: "S1", score_source: "ai", weight: 30, threshold: 60)
    job.stages.create!(code: "S5", score_source: "scorecard", weight: 70, threshold: 70)
    job
  end

  def apply!(job, key, cv)
    consent = ConsentTemplate.in_force or raise "no consent text in force: publish one on System settings first"
    candidate = Candidate.create!(name: "Release Applicant #{key}", email: "release.#{key.downcase}.#{job.id}@contoh.example",
                                  phone: format("0812-0000-%04d", 1100 + key.ord - 64))
    application = JobApplication.create!(job:, candidate:, consent_at: Time.current, consent_template: consent,
                                         consent_retention_days: SystemSetting.retention_days || 30,
                                         cv_text: cv, cv_text_source: "pdf", cv_text_at: Time.current)
    # The callback queues the screening job; it runs inline (see with_inline_screening).
    Participation.create!(job_application: application, stage: job.stages.find_by!(code: "S1"))
  end

  # D: the reviewer's release, written as AiReleases::Release writes it. The service itself refuses
  # without an API key (correctly: the text could not be sent), so the action row is inserted
  # directly; the database still checks the reviewer, the consultant rule and the digest. The job
  # then tries to send, finds no key, and fails visibly ("config").
  def release!(participation, reviewer)
    release = AiRelease.latest_for(participation)
    ActiveRecord::Base.transaction do
      AiReleaseAction.create!(ai_release: release, action: "released", actor: reviewer, checked: true,
                              payload_sha256: release.payload_sha256, created_at: Time.current)
      Screening::ReleaseHandler.after_release(release)
    end
    ScreenParticipationJob.perform_now(participation.id)
  end

  def with_inline_screening
    previous = ScreenParticipationJob.queue_adapter
    ScreenParticipationJob.queue_adapter = ActiveJob::QueueAdapters::InlineAdapter.new
    yield
  ensure
    ScreenParticipationJob.queue_adapter = previous
  end
end
