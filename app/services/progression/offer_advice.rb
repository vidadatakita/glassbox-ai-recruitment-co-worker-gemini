# frozen_string_literal: true

module Progression
  # AI advice in the Job offer section (17 Oct 2026). Two parts, deliberately different:
  #   - draft: Gemini drafts the "First-day preparation" text the applicant reads after accepting,
  #     from the BRIEF only (position, 90-day target, main activities and their outputs, must-haves).
  #     No salary or amount (the AI never sees money, FLOW §7), no applicant name, contact or CV.
  #     The HR Admin edits it before the offer is uploaded; nothing is stored by this service.
  #   - checklist: computed here, not by the AI, so it can never be wrong for a reason a model invented.
  module OfferAdvice
    class Refused < StandardError; end

    PROMPT_VERSION = "offer-first-day-2026-10-17.1"
    Check = Data.define(:label, :ok, :hint)

    SYSTEM = <<~PROMPT.freeze
      You write the "first-day preparation" note a new employee reads after accepting a job offer.
      Use only the facts given: the position, the 90-day target, the main activities with their
      expected outputs, and the must-have requirements. Write in plain, warm English, 90 to 140 words,
      as 4 to 6 short lines a person can act on: what to bring, who they will meet, what the first week
      covers, how the 90-day target will be reviewed. Do not mention salary, pay, benefits or any
      amount. Do not invent names, addresses, dates or times; where one is needed write "[to be
      confirmed by HR]". Do not mention age, gender, religion, ethnicity, marital status or appearance.
    PROMPT
    SCHEMA = Briefs::Suggest::ROW.call(day_one_notes: { type: "string" }).freeze

    module_function

    def draft(application:, actor:)
      raise Refused, "Only the HR Admin prepares the offer." unless Progression.chooser?(actor)
      raise Refused, "The AI feature is off." unless Screening::Config.enabled?

      job = application.job
      facts = {
        position: job.title, company: job.client_company&.name, location: job.location,
        employment: Job::EMPLOYMENT_TYPES[job.employment_type], ninety_day_target: job.success_90d,
        main_activities: job.activities.map { |a| { activity: a.description, expected_output: a.output } },
        must_haves: job.requirements.select { |r| r.tier == "wajib" }.map(&:text)
      }
      reply = Screening::Config.client(:letter, job:).generate(system: SYSTEM, schema: SCHEMA, content: JSON.pretty_generate(facts.compact))
      text = JSON.parse(reply.text)["day_one_notes"].to_s.strip
      raise Refused, "The AI returned no text. Try again." if text.empty?

      text
    rescue Screening::Errors::Transient
      raise Refused, "The AI is busy. Try again in a minute."
    rescue Screening::Errors::Base, JSON::ParserError
      raise Refused, "The AI could not write the note. Write it yourself or try again."
    end

    # The offer summary for the approver (Vida, 17 Oct 2026): why this applicant was chosen, for the
    # person who signs the offer. Assembled from what is RECORDED, not a new AI call: the stage results
    # (ScoreMatrix, which applies the D13 blinding) and the latest ready AI advice on the furthest step
    # (its summary, strengths and gaps, written from the verified evidence). No salary, no contact data.
    # HR edits the text on screen before using it; nothing is stored.
    def approver_summary(application, matrix)
      rec = application.participations.includes(:stage).sort_by { |p| Progression.order_of(p.stage) }.reverse
                       .lazy.filter_map { |p| StageRecommendation.latest_for(p) }.find(&:ready?)
      reasons = rec&.reasons || {}
      lines = ["Position: #{application.job.title}."]
      results = matrix.rows.select { |r| r.score || r.outcome || r.hidden }.map do |r|
        outcome = ScoreMatrix::OUTCOME_LABELS.fetch(r.outcome, "in progress")
        if r.hidden then "#{r.label}: hidden until calibration is judged"
        elsif r.score then "#{r.label} #{r.score.to_f} (pass score #{r.threshold.to_f}): #{outcome}"
        else "#{r.label}: #{outcome} (decided at the screening gate)"
        end
      end
      lines << "Results: #{results.join('; ')}." if results.any?
      lines << "Cumulative score: #{matrix.cumulative.to_f}." if matrix.cumulative
      if rec
        lines << "AI advice (#{rec.advice_label}): #{rec.summary}"
        lines += Array(reasons["strengths"]).first(3).map { |s| "Strength: #{s}" }
        lines += Array(reasons["gaps"]).first(3).map { |g| "Gap: #{g}" }
      end
      lines << "Decided by a person at every step; the salary is agreed separately by the HR Manager or the Superadmin."
      lines.join("\n")
    end

    # What must be true before the offer goes out; each line says how to fix it.
    def checklist(application)
      agreement = SalaryAgreement.where(job_application_id: application.id).order(:created_at).last
      [
        Check.new("Salary agreed by the HR Manager or Superadmin", agreement.present?, agreement ? nil : "Agreed in the Salary section, which opens once the last stage is passed."),
        Check.new("Consent still in force", application.consent_withdrawn_at.nil?, application.consent_withdrawn_at ? "The applicant withdrew consent; do not send an offer." : nil),
        Check.new("Offer letter (PDF) chosen", nil, "Choose the PDF below."),
        Check.new("Start date and answer-by date set", nil, "Fill both dates below.")
      ]
    end
  end
end
