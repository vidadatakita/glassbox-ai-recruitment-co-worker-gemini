# Demo data for feature 08, "Laporan Analisis Kandidat" (D61, D62).
#
# EVERYTHING HERE IS INVENTED: the job, the nine candidates ("Kandidat Contoh A" ... "I", the
# placeholder names SPEC §3 itself uses), their CV texts, employers, salaries and scores. No real
# candidate data (SPEC §4). No AI was called: the S1 results carry the model id
# "demo-tanpa-ai (data contoh)" so nobody can mistake them for a model's judgement.
#
# Two jobs, so both visibility states exist side by side:
#   OPEN   gate "Seleksi CV dan Tes Teknis" still open -> HR PIC and owner see "Kandidat 01..."
#   CLOSED gate closed through Gates::Close            -> names visible; E and F get gate_eliminated
# Rows cover SPEC §3 (A: AI 4/5, test 82, Lolos, Rp7-8 jt, Direkomendasikan; B: 4/5, 58, Tidak lolos
# (tes), Rp6-7 jt, Pertimbangkan terbatas; C: 5/5, 91, Lolos, Rp14-18 jt, Over-qualified) plus every
# other label and test state (menunggu penilaian, sedang dikerjakan, belum dikerjakan, kedaluwarsa).
# D52 (GlassBox Team 18:0x, "buat seeder untuk data contohnya semua") coverage, all invented: the six Analisa
# labels; gate results Lolos / Menunggu / Tidak lolos (CV) / Tidak lolos (tes); names hidden (open
# job) and shown (closed job); expected salary below, inside, above the band and not given;
# Rekomendasi User and Jadwal Interview present (A) and absent (the rest); narratives approved (A, C)
# and "Draf AI" (the rest); Kota domisili given (A, B, C, G) and empty (the rest) (D54).
#
# Written through the real services where one exists (TestCases::SaveVersion/Approve, Gates::Open/
# Close, TechnicalTests::SubmitAnswer/ScoreAnswer, ScreeningReport::ConfirmLabel/
# RecordUserRecommendation), so a seed that breaks a rule fails loudly. The AI's own rows
# (ScoreEntry by actor 0, ScreeningResult) are inserted as Screening::Run would, without the call.
# Idempotent: a job that already exists (by title) is left alone; each job is one transaction.
require_relative "demo_test_cases"

module DemoScreeningReport
  TITLES = {
    open: "Supervisor Keuangan (Demo Laporan, gerbang terbuka)",
    closed: "Supervisor Keuangan (Demo Laporan, gerbang ditutup)"
  }.freeze
  MODEL_ID = "demo-tanpa-ai (data contoh)".freeze

  CV = <<~CV.freeze
    PENGALAMAN KERJA
    %<role>s di %<employer>s (2021 - sekarang)
    Menyusun jurnal umum dan rekonsiliasi bank bulanan
    Memimpin tim 4 staf akuntansi
    PENDIDIKAN
    %<education>s
    KEAHLIAN
    Microsoft Excel tingkat lanjut, pivot dan lookup
  CV

  # key => [role, employer, education, s1 ratings [sebaiknya1, sebaiknya2], wajib met?, label proposal,
  #         salary [min, max] or nil, s2 plan, s2 ratings [r1, r2, r3], confirmed label or nil]
  # s2 plan: :scored, :answered, :running, :none, :no_show. Rubric weights 36/32/32: ratings 3/5/5
  # give 82.0, 3/2/5 give 58.0, 4/5/5 give 91.0 (TechnicalTests::RubricScore).
  PEOPLE = {
    "A" => ["Supervisor Akuntansi", "PT Contoh Niaga", "S1 Akuntansi, Universitas Contoh", [3, 1], true, "direkomendasikan",
            [7_000_000, 8_000_000], :scored, [3, 5, 5], "direkomendasikan"],
    "B" => ["Staf Keuangan Senior", "PT Contoh Logistik", "D3 Akuntansi, Politeknik Contoh", [2, 2], true, "pertimbangkan_terbatas",
            [6_000_000, 7_000_000], :scored, [3, 2, 5], "pertimbangkan_terbatas"],
    "C" => ["Manajer Keuangan", "PT Contoh Sentosa", "S2 Akuntansi, Universitas Contoh", [3, 2], true, "pertimbangkan",
            [14_000_000, 18_000_000], :scored, [4, 5, 5], "over_qualified"],
    "D" => ["Staf Akuntansi", "CV Contoh Mandiri", "S1 Akuntansi, Universitas Contoh", [3, 2], true, "pertimbangkan",
            nil, :answered, nil, nil],
    "E" => ["Admin Keuangan", "Toko Contoh Jaya", "D3 Akuntansi, Politeknik Contoh", [1, 1], true, "tidak_prioritas",
            [5_000_000, 6_000_000], :none, nil, nil],
    "F" => ["Staf Gudang", "PT Contoh Distribusi", "SMA Contoh", [0, 0], false, "tidak_relevan",
            nil, :none, nil, nil],
    "G" => ["Supervisor Akuntansi", "PT Contoh Agro", "S1 Akuntansi, Universitas Contoh", [3, 2], true, "direkomendasikan",
            [8_000_000, 9_000_000], :running, nil, nil],
    "H" => ["Staf Akuntansi", "PT Contoh Retail", "S1 Akuntansi, Universitas Contoh", [3, 1], true, "pertimbangkan",
            [7_500_000, 8_000_000], :none, nil, nil],
    "I" => ["Staf Pajak", "KAP Contoh", "S1 Akuntansi, Universitas Contoh", [3, 1], true, "pertimbangkan",
            [7_000_000, 7_500_000], :no_show, nil, nil]
  }.freeze
  # The closed job keeps only people who can be decided before the gate closes.
  CLOSED_PEOPLE = %w[A B C E F I].freeze

  module_function

  # Two steps per job, on purpose: the test-case freeze trigger is DEFERRED, so saving, approving
  # and starting a version inside one transaction fails at commit ("version 1 has been started by a
  # candidate and is frozen"). Step 1 builds the job and its approved test; step 2 (one
  # transaction) adds the applicants. Idempotent: a job is created once, applicants only into an
  # empty S1.
  def run(company:, hr:, consultant:, reviewer:, now: Time.current)
    TITLES.map do |state, title|
      # base runs WITHOUT an outer transaction: the test-case services commit their own, and the
      # deferred freeze trigger refuses a version saved and approved inside one enclosing transaction.
      job = Job.find_by(title:) || base(title, company:, hr:, consultant:, now:)
      raise "#{title}: no approved test version (a half-built demo job); remove it from the dev database by hand" unless TechnicalTestCase.current_for(job)
      stages = %w[S1 S2 S3].to_h { |code| [code.downcase.to_sym, job.stages.find_by!(code:)] }
      unless stages[:s1].participations.exists?
        ActiveRecord::Base.transaction { populate(job, state, stages, consultant:, reviewer:, hr:, now:) }
      end
      approve_narratives(job, consultant)
      cities(job)
      job
    end
  end

  def base(title, company:, hr:, consultant:, now:)
    job = Job.create!(title:, golongan: 4, client_company: company, location: "Bekasi", salary_min: 7_500_000,
                      salary_max: 9_000_000, consultant:, package: 3, brief_status: "complete")
    activities(job)
    requirements(job)
    stages = stages(job)
    test_case(job, consultant:, hr:)
    Gates::Open.call(stage: stages[:s1], now: now - 3.days)
    job
  end

  def populate(job, state, stages, consultant:, reviewer:, hr:, now:)
    test_case = TechnicalTestCase.current_for(job)
    keys = state == :open ? PEOPLE.keys : CLOSED_PEOPLE
    keys.each { |key| applicant(job, key, stages, test_case, consultant:, reviewer:, hr:, now:) }
    Gates::Close.call(stage: stages[:s1], now:) if state == :closed
  end

  # D62 h2 both states on the screen: A and C carry narratives approved by the consultant, every
  # other candidate stays "Draf AI". Its own idempotent step (an existing approval is skipped), so a
  # dev database seeded before this step was added catches up on the next run.
  APPROVED_NARRATIVES = %w[A C].freeze

  def approve_narratives(job, consultant)
    APPROVED_NARRATIVES.each do |key|
      application = JobApplication.joins(:candidate).find_by(job:, candidates: { name: "Kandidat Contoh #{key}" })
      result = application && ScreeningResult.current_for(application.participations.select(:id)).first
      next if result.nil? || ScreeningNarrativeApproval.exists?(screening_result_id: result.id)

      ScreeningReport::ApproveNarratives.call(result:, user: consultant, note: "Data contoh: narasi diperiksa konsultan.")
    end
  end

  # D54: some invented candidates give a city, the rest leave it empty (both states on screen).
  # Its own idempotent step, so a dev database seeded before D54 catches up.
  CITIES = { "A" => "Bekasi", "B" => "Karawang", "C" => "Jakarta", "G" => "Bandung" }.freeze

  def cities(job)
    CITIES.each do |key, city|
      JobApplication.joins(:candidate).where(job:, domicile_city: nil, candidates: { name: "Kandidat Contoh #{key}" })
                    .update_all(domicile_city: city)
    end
  end

  def activities(job)
    [["Menyusun jurnal dan laporan keuangan bulanan", "Laporan keuangan tepat waktu", 50],
     ["Rekonsiliasi bank dan kas", "Selisih kas terjelaskan", 30],
     ["Memimpin dan memeriksa pekerjaan staf", "Kesalahan staf turun", 20]].each_with_index do |(d, o, s), i|
      job.activities.create!(position: i + 1, description: d, output: o, share_percent: s)
    end
  end

  def requirements(job)
    [["wajib", "Pendidikan minimal D3 Akuntansi", "Ijazah D3/S1 Akuntansi di CV", nil],
     ["sebaiknya", "Pengalaman menyusun jurnal dan rekonsiliasi", "Riwayat kerja menyusun jurnal", 60],
     ["sebaiknya", "Mahir Microsoft Excel", "Keahlian Excel disebut", 40],
     ["nilai_tambah", "Pengalaman memimpin tim", "Memimpin staf disebut", nil]].each_with_index do |(tier, text, evidence, weight), i|
      job.requirements.create!(tier:, text:, cv_evidence: evidence, weight:, position: i + 1)
    end
  end

  def stages(job)
    s1 = job.stages.create!(code: "S1", score_source: "ai", weight: 10, threshold: 60, gate: "screening")
    s2 = job.stages.create!(code: "S2", score_source: "manual_or_import", weight: 20, threshold: 60, gate: "screening")
    s3 = job.stages.create!(code: "S3", score_source: "scorecard", weight: 20, threshold: 65)
    job.stages.create!(code: "S5", score_source: "scorecard", weight: 50, threshold: 70)
    { s1:, s2:, s3: }
  end

  def test_case(job, consultant:, hr:)
    rows = [["Tanggal", "Akun", "Debit", "Kredit"], ["01-09-2026", "Kas", 5_000_000, nil], ["01-09-2026", "Pendapatan", nil, 5_500_000]]
    params = { instructions: "Lembar Data berisi jurnal satu bulan dengan 3 kesalahan. Perbaiki di lembar Jawaban.",
               time_limit_minutes: "35", answer_types_submitted: "1", answer_types: %w[xlsx],
               case_file: DemoTestCases::SeedUpload.new(DemoTestCases.workbook("Kasus jurnal (data fiktif).", rows), "kasus-jurnal.xlsx"),
               criteria: [[0, "Menemukan kesalahan jurnal", 36], [1, "Rekonsiliasi yang benar", 32], [2, "Penjelasan untuk tim", 32]]
                 .each_with_index.to_h do |(a, name, w), i|
                 [i.to_s, { activity_id: job.activities[a].id.to_s, name:, weight: w.to_s, anchor_1: "Tidak ditemukan",
                            anchor_3: "Sebagian ditemukan", anchor_5: "Semua ditemukan dan dijelaskan" }]
               end }
    saved = TestCases::SaveVersion.call(job:, actor: consultant, params:)
    raise "demo test case refused: #{saved.errors.join(' | ')}" unless saved.ok?

    approved = TestCases::Approve.call(test_case: saved.test_case, actor: hr)
    raise "demo test case not approved: #{approved.errors.join(' | ')}" unless approved.ok?

    saved.test_case.reload
  end

  # name: the candidate's invented name; the report's own jobs keep the SPEC placeholder
  # "Kandidat Contoh <key>", another demo (DemoCup) passes realistic invented names.
  def applicant(job, key, stages, test_case, consultant:, reviewer:, hr:, now:, name: nil)
    role, employer, education, ratings, wajib, proposal, salary, plan, s2_ratings, confirm = PEOPLE.fetch(key)
    applied = plan == :no_show ? now - 3.days : now - 30.hours
    applied = now - 2.hours if %i[none running].include?(plan) && key != "E"
    application = application_for(job, key, salary, applied, cv: format(CV, role:, employer:, education:), consultant:, name:)
    p1 = Participation.create!(job_application: application, stage: stages[:s1], attendance: "attended")
    p2 = Participation.create!(job_application: application, stage: stages[:s2], attendance: "pending")
    s1_result(job, p1, application, role, employer, education, ratings, wajib, proposal, now:)
    s2(application, p2, test_case, plan, s2_ratings, reviewer:, applied:, now:)
    extras(key, application, p1, stages, confirm, reviewer:, hr:, now:)
  end

  def application_for(job, key, salary, applied, cv:, consultant:, name: nil)
    candidate = Candidate.create!(name: name || "Kandidat Contoh #{key}", email: "kandidat.#{key.downcase}.#{job.id}@contoh.example",
                                  phone: format("0812-0000-%04d", job.id * 10 + key.ord - 64))
    consent = ConsentTemplate.in_force or raise "no consent text in force: publish one on Pengaturan Sistem first"
    JobApplication.create!(job:, candidate:, consent_at: applied, consent_template: consent,
                           consent_retention_days: SystemSetting.retention_days || 30, created_at: applied,
                           expected_salary_min: salary&.first, expected_salary_max: salary&.last,
                           cv_text: cv, cv_text_source: "pasted", cv_text_at: applied, cv_text_by_id: consultant.id)
  end

  def s1_result(job, participation, application, role, employer, education, ratings, wajib, proposal, now:)
    rubric = Screening::Rubric.for(job)
    cv = application.cv_text
    quotes = { "wajib" => education, "sebaiknya" => "Menyusun jurnal umum dan rekonsiliasi bank bulanan", "nilai_tambah" => "Memimpin tim 4 staf akuntansi" }
    sebaiknya = rubric.criteria.select { |c| c.tier == "sebaiknya" }
    judgements = rubric.criteria.to_h do |c|
      j = case c.tier
          when "wajib" then wajib ? "met" : "not_met"
          when "sebaiknya" then ratings[sebaiknya.index(c)].to_s
          else "2"
          end
      quote = %w[not_met 0].include?(j) ? "" : (c.text.include?("Excel") ? "Microsoft Excel tingkat lanjut, pivot dan lookup" : quotes.fetch(c.tier))
      [c.key, { "judgement" => j, "quote" => quote, "verified" => Screening::QuoteCheck.verified?(judgement: j, quote:, extracted: cv, redacted: cv) }]
    end
    score = Screening::Score.compute(rubric, judgements)
    # Screened a day before `now`, but never before the application arrived (a late applicant is
    # screened ten minutes after applying), so "time to first answer" is never negative.
    at = [now - 1.day, application.created_at + 10.minutes].max
    entry = ScoreEntry.create!(participation:, value: score.score, ratings: {}, entered_by_id: Screening::AI_ACTOR_ID,
                               event_at: application.created_at, entered_at: at, model_id: MODEL_ID,
                               prompt_version: Screening::PROMPT_VERSION)
    check = ->(q) { Screening::QuoteCheck.verified?(judgement: "met", quote: q, extracted: cv, redacted: cv) }
    claim = ->(text, q) { { "claim" => text, "quote" => q, "verified" => check.(q) } }
    line = "#{role} di #{employer} (2021 - sekarang)"
    ScreeningResult.create!(
      participation:, score_entry: entry, rubric_digest: rubric.digest, model_id: MODEL_ID, prompt_version: Screening::PROMPT_VERSION,
      judgements: rubric.criteria.map { |c| j = judgements.fetch(c.key); { "requirement_id" => c.requirement_id, "key" => c.key, "tier" => c.tier, "text" => c.text, "weight" => c.weight }.merge(j) },
      score: score.score, wajib_met: score.wajib_met, unverified_count: score.unverified_count, bonus_points: score.bonus_points,
      bonus_possible: score.bonus_possible, created_at: at,
      last_position: { "text" => "#{role}, #{employer}", "quote" => line, "verified" => check.(line) },
      education: { "text" => education, "quote" => education, "verified" => check.(education) },
      recent_experience: { "text" => "Menyusun jurnal dan rekonsiliasi bank; memimpin tim kecil.", "quote" => "Menyusun jurnal umum dan rekonsiliasi bank bulanan", "verified" => true },
      narratives: {
        "strengths" => [claim.("Terbiasa dengan siklus tutup buku bulanan", "Menyusun jurnal umum dan rekonsiliasi bank bulanan")],
        "blind_spots" => [claim.("Belum terlihat pengalaman audit eksternal", "")],
        "tolerance_risks" => [claim.("Tim yang dipimpin masih kecil", "Memimpin tim 4 staf akuntansi")],
        "credibility_value" => [claim.("Keahlian Excel mendukung laporan cepat", "Microsoft Excel tingkat lanjut, pivot dan lookup")]
      },
      label_proposal: proposal, label_reason: "Data contoh: alasan usulan ditulis AI pada lowongan nyata."
    )
    participation.update!(screening_state: "done", screening_state_at: at)
    outcome = Screening::Score.outcome(wajib_met: score.wajib_met, score: score.score, threshold: participation.stage.threshold)
    Decision.create!(participation:, outcome: outcome.outcome.to_s, basis: outcome.basis.to_s, reason_code: outcome.reason_code,
                     decided_at: at)
  end

  def s2(application, participation, test_case, plan, ratings, reviewer:, applied:, now:)
    case plan
    when :scored, :answered
      started = applied + 1.hour
      TestAttempt.create!(participation:, test_case:, started_at: started, due_at: started + test_case.time_limit_minutes.minutes)
      answer = DemoTestCases::SeedUpload.new(DemoTestCases.workbook("Jawaban (data fiktif).", [["Baris", "Koreksi"], [2, 5_500_000]]), "jawaban.xlsx")
      attempt = TechnicalTests::SubmitAnswer.call(application:, file: answer, now: started + 31.minutes)
      return if plan == :answered

      ratings_by_id = test_case.criteria.sort_by(&:position).each_with_index.to_h { |c, i| [c.id.to_s, ratings[i].to_s] }
      TechnicalTests::ScoreAnswer.call(attempt:, reviewer:, ratings: ratings_by_id, note: "Data contoh: penilaian rubrik.", now: now - 2.hours)
    when :running
      started = now - 5.minutes
      TestAttempt.create!(participation:, test_case:, started_at: started, due_at: started + test_case.time_limit_minutes.minutes)
    when :no_show
      participation.update!(attendance: "no_show")
      result = Scoring::Decider.decide(score: nil, threshold: participation.stage.threshold, attendance: :no_show)
      Decision.create!(participation:, outcome: result.outcome.to_s, basis: result.basis.to_s, reason_code: result.reason_code, decided_at: now - 1.hour)
    end
  end

  def extras(key, application, p1, stages, confirm, reviewer:, hr:, now:)
    if confirm
      golongan = confirm == "over_qualified" ? 6 : nil
      note = confirm == "over_qualified" ? "Posisi terakhir manajer (G6), dua Golongan di atas lowongan G4. Data contoh." : nil
      ScreeningReport::ConfirmLabel.call(participation: p1, reviewer:, label: confirm, last_role_golongan: golongan, note:)
    end
    return unless key == "A"

    p3 = Participation.create!(job_application: application, stage: stages[:s3], attendance: "pending")
    Appointment.create!(participation: p3, starts_at: (now + 3.days).change(hour: 9), ends_at: (now + 3.days).change(hour: 10),
                        mode: "onsite", place_or_link: "Kantor contoh, Ruang Rapat 2", contact: "HR (data contoh)")
    ScreeningReport::RecordUserRecommendation.call(application:, user: hr, user_name: "Ibu Ratna (Manajer Keuangan, data contoh)",
                                                   pick: "lanjut", note: "Data contoh.")
  end
end
