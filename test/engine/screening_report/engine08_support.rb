# Test engine, feature 08 "Laporan Analisis Kandidat" (D61, D62, D53): fixtures owned by the
# engine, independent of the builder's test/support/report_factory.rb and the demo seed, so a later
# change to those cannot quietly change what these tests prove. Every name, CV line and figure is
# INVENTED.
#
# S1 results are inserted DIRECTLY (ScoreEntry by the AI actor + ScreeningResult), the way
# Screening::Run persists them, WITHOUT the pipeline: the D51 release-gate work was editing run.rb
# and the enqueue path while this engine runs, and a test that goes through the pipeline could go
# red for a reason that is not feature 08. Only pipeline_test.rb uses the stubbed pipeline.
require "zip"

module Engine08Support
  MODEL = "e8-model-uji".freeze
  PROMPT = "s1-e8-uji".freeze

  # A gated job (package 3 shape: S1 + S2 gate "screening", S5) or a package-2 job (S1 only), open.
  def e8_job(gated: true, golongan: 4, salary: [7_500_000, 9_000_000], consultant: staff_user("consultant"), title: "Supervisor Uji E8")
    job = Job.create!(title:, golongan:, client_company: company, location: "Bekasi", salary_min: salary&.first,
                      salary_max: salary&.last, consultant:, package: gated ? 3 : 2, brief_status: "complete")
    s1 = job.stages.create!(code: "S1", score_source: "ai", weight: 10, threshold: 60, gate: gated ? "screening" : nil)
    s2 = gated ? job.stages.create!(code: "S2", score_source: "manual_or_import", weight: 20, threshold: 60, gate: "screening") : nil
    job.stages.create!(code: "S5", score_source: "scorecard", weight: 70, threshold: 70)
    gated ? Gates::Open.call(stage: s1, now: 3.days.ago) : Stages::Open.call(stage: s1, now: 3.days.ago)
    job.stages.reload
    [job, s1.reload, s2&.reload]
  end

  # One applicant in S1 (and S2 when the job is gated). name nil = no candidate row.
  def e8_applicant(job, s1, s2, name:, email: nil, phone: nil, salary: nil, applied: 30.hours.ago)
    candidate = Candidate.create!(name:, email: email || "#{name.parameterize}.e8@uji.example", phone: phone || "0813-9999-0001")
    application = JobApplication.create!(job:, candidate:, consent_at: applied, consent_template: publish_consent,
                                         consent_retention_days: 30, created_at: applied,
                                         expected_salary_min: salary&.first, expected_salary_max: salary&.last)
    p1 = Participation.create!(job_application: application, stage: s1, attendance: "attended")
    p2 = s2 && Participation.create!(job_application: application, stage: s2, attendance: "pending")
    [application, p1, p2]
  end

  def e8_fact(text, quote: text, verified: true) = { "text" => text, "quote" => quote, "verified" => verified }
  def e8_claim(claim, quote:, verified: true) = { "claim" => claim, "quote" => quote, "verified" => verified }

  # A current S1 result with chosen score, label proposal and report fields.
  def e8_result(p1, score:, label: "pertimbangkan", last_position: e8_fact("Supervisor Akuntansi, PT Uji Niaga"),
                narratives: e8_narratives, judgements: e8_judgements, model: MODEL, prompt: PROMPT, at: 1.day.ago)
    entry = ScoreEntry.create!(participation: p1, value: score, ratings: {}, entered_by_id: Screening::AI_ACTOR_ID,
                               event_at: at, entered_at: at, model_id: model, prompt_version: prompt)
    ScreeningResult.create!(participation: p1, score_entry: entry, rubric_digest: "e8-digest", model_id: model,
                            prompt_version: prompt, judgements:, score:, wajib_met: true, unverified_count: 0,
                            created_at: at, last_position:, education: e8_fact("S1 Akuntansi, Universitas Uji"),
                            recent_experience: e8_fact("Menyusun jurnal bulanan.", quote: "Menyusun jurnal umum"),
                            narratives:, label_proposal: label, label_reason: "Alasan uji.")
  end

  def e8_narratives(strengths: [e8_claim("Teliti", quote: "Menyusun jurnal umum")])
    { "strengths" => strengths, "blind_spots" => [], "tolerance_risks" => [], "credibility_value" => [] }
  end

  def e8_judgements(sebaiknya: "3")
    [{ "requirement_id" => nil, "key" => "wajib_1", "tier" => "wajib", "text" => "Pendidikan D3 Akuntansi", "weight" => nil,
       "judgement" => "met", "quote" => "S1 Akuntansi", "verified" => true },
     { "requirement_id" => nil, "key" => "sebaiknya_1", "tier" => "sebaiknya", "text" => "Menyusun jurnal", "weight" => 100,
       "judgement" => sebaiknya, "quote" => "Menyusun jurnal umum", "verified" => true }]
  end

  # A manual decision (the only basis allowed without an attended threshold score in every state).
  # The consultant judges every calibration CV of the job, so the report shows the AI results to the
  # people who judge calibration (Screening::CalibrationBlind, 18 Oct 2026). Call after the results exist.
  def e8_judge_calibration!(job)
    Screening::Calibration.new(job).rows.each do |row|
      next if row.judgement

      Screening::JudgeCalibration.call(participation: row.participation, user: job.consultant, outcome: "pass")
    end
  end

  def e8_decide(participation, outcome, by: staff_user("consultant"))
    Decision.create!(participation:, outcome:, basis: "manual", reason_code: "manual", note: "keputusan uji E8",
                     decided_by_id: by.id, decided_at: Time.current,
                     supersedes_id: Decision.current.where(participation_id: participation.id).pick(:id))
  end

  def e8_s2_score(p2, value, by: staff_user("reviewer"))
    p2.update!(attendance: "attended") unless p2.attendance == "attended"
    ScoreEntry.create!(participation: p2, value:, ratings: {}, entered_by_id: by.id, event_at: Time.current, entered_at: Time.current)
  end

  # The xlsx bytes read back as rows of cell texts; a formula cell reads "=<f>|<cached v>".
  def e8_xlsx(body)
    Zip::File.open_buffer(StringIO.new(body)) do |zip|
      strings = zip.find_entry("xl/sharedStrings.xml") ? Nokogiri::XML(zip.read("xl/sharedStrings.xml")).remove_namespaces!.css("si").map { |si| si.css("t").map(&:text).join } : []
      sheet = Nokogiri::XML(zip.read("xl/worksheets/sheet1.xml")).remove_namespaces!
      rows = sheet.css("sheetData row").map do |row|
        row.css("c").map do |c|
          if c["t"] == "s" then strings[c.at("v").text.to_i]
          elsif c.at("f") then "=#{c.at('f').text}|#{c.at('v')&.text}"
          else c.at("v")&.text || c.at("is t")&.text
          end
        end
      end
      all_xml = zip.entries.select(&:file?).map { |e| zip.read(e.name).force_encoding("UTF-8") }.join("\n")
      return { rows:, all: all_xml, header: rows[3] }
    end
  end

  def e8_board(job, user, now: Time.current) = ScreeningReportBoard.new(job.reload, user, now:)
end
