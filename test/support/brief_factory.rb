require_relative "test_case_factory"
# Builders for the job-form tests (feature 03). Every text is invented demo content.
module BriefFactory
  include TestCaseFactory
  # Competencies that cover every layer, so any Golongan passes the §2.3 coverage check unless a
  # test removes one on purpose.
  ALL_LAYERS = %w[L1 L2 L3 L4 L5 I].freeze

  def step1_params(golongan: 2, title: "Operator Uji")
    { title:, golongan: golongan.to_s, headcount: "2", employment_type: "kontrak_pkwt", confidential: "0" }
  end

  def step2_params(shares: [30, 20, 20, 15, 15])
    { success_90d: "Menjalankan mesin sesuai standar tanpa pendampingan.",
      activities: shares.each_with_index.to_h { |s, i| [i.to_s, { description: "Aktivitas uji #{i + 1}", output: "Hasil #{i + 1}", share_percent: s.to_s }] } }
  end

  def step3_params(knockouts: ["Bersedia bekerja shift?", "Pengalaman minimal 1 tahun?"], weights: [60, 40])
    rows = knockouts.each_with_index.map { |q, i| { tier: "wajib", text: "Syarat wajib #{i + 1}", cv_evidence: "Tertulis di CV", knockout: q } }
    rows << { tier: "wajib", text: "Syarat wajib tanpa knockout", cv_evidence: "Sertifikat" }
    rows += weights.each_with_index.map { |w, i| { tier: "sebaiknya", text: "Syarat sebaiknya #{i + 1}", cv_evidence: "Riwayat kerja", weight: w.to_s } }
    rows << { tier: "nilai_tambah", text: "Nilai tambah", cv_evidence: "Kursus" }
    { salary_min: "5.200.000", salary_max: "6.000.000", show_salary: "1", placements: ["Bekasi", "Karawang"],
      relocation: "diutamakan", work_arrangement: "onsite", requirements: rows.each_with_index.to_h { |r, i| [i.to_s, r] } }
  end

  def step4_params(package: 3, golongan: 2, layers: ALL_LAYERS, reason: nil, weights: nil, threshold: "60")
    reason = "Full stage set kept for this test." if reason.nil? && package.to_i >= 4
    codes = Briefs::StagePlan.scored_codes(package)
    weights ||= Briefs::StagePlan.default_weights(package)
    stage = codes.first
    { package: package.to_s, package_override_reason: reason,
      stage_plan: codes.to_h { |c| [c, { weight: weights[c].to_s, threshold: }] },
      competencies: layers.each_with_index.to_h do |layer, i|
        [i.to_s, { name: "Kompetensi #{layer}", layer:, stage_code: (codes.include?("S3") ? "S3" : stage),
                   anchor_1: "Hasil perlu diulang", anchor_3: "Sesuai standar", anchor_5: "Sesuai standar dan memperbaiki cara",
                   questions: "Ceritakan contoh pekerjaan terakhir Anda." }]
      end }
  end

  # The step-3 form carries each saved requirement's id in a hidden field; this does the same, in
  # slot order, so an edit updates rows (and their knockout questions) in place.
  def with_requirement_ids(job, params)
    ids = job.requirements.reload.map(&:id)
    params[:requirements].each_value.with_index { |row, i| row[:id] = ids[i]&.to_s }
    params
  end

  def save_step!(job, step, params, actor: staff_user("hr_pic"))
    result = Briefs::SaveStep.call(job:, step:, params:, actor:)
    assert result.ok?, "step #{step} refused: #{result.errors.inspect}"
    result.job
  end

  # A job whose brief passes Briefs::BriefCheck, saved through the same service the screens use.
  # D60 slice 2: when the package runs S2, "passes" includes an approved technical-test version, so
  # the factory adds one (consultant uploads, HR PIC approves) unless test_case: false asks for a
  # brief that still lacks it.
  def briefed_job(golongan: 2, package: 3, complete: true, test_case: true, ad: true)
    job = save_step!(Job.new(client_company: company), "1", step1_params(golongan:))
    save_step!(job, "2", step2_params)
    save_step!(job, "3", step3_params)
    save_step!(job, "4", step4_params(package:, golongan:,
                                      reason: (Briefs::PackageAdvisor.recommended?(golongan, package) ? nil : "Klien meminta")))
    approved_test_case!(job) if test_case && TestCases::Requirement.applies?(job)
    if complete
      result = Briefs::Complete.call(job:, actor: staff_user("hr_pic"))
      assert result.ok?, "complete refused: #{result.problems.map(&:message).inspect}"
      # A complete brief in the product now has its ad written before HR approves it (AI Builder Cup
      # step 02: "Iklan belum ditulis" refuses an empty ad). Invented text, no flagged phrases.
      # ad: false keeps the ad unwritten, for the tests of that refusal.
      job.update_columns(ad_text: "Kami mencari #{job.title} untuk bergabung dengan tim gudang di Bekasi.") if ad && job.ad_text.blank?
    end
    job.reload
  end
end
