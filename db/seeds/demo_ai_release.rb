# Demo data for feature 09, "Pemeriksaan sebelum AI" (D51 B; D52 "buat seeder untuk data
# contohnya semua").
#
# EVERYTHING HERE IS INVENTED: the job, the five candidates ("Pelamar Rilis A" ... "E"),
# their CV texts, employers and dates. No AI is called: development has no API key, and the one
# released text fails visibly with "Kunci API belum diatur" when the job tries to send it, exactly
# as production would without a key.
#
# One job, five CVs, one per state the release screen shows:
#   A  Menunggu pemeriksaan, clean text (no residual finding)
#   B  Menunggu pemeriksaan WITH residual findings (a birth date inside the experience section) and
#      protected-word hints (family, worship); "Kirim ke AI" is refused until the line is cut
#   C  no evidence section -> "Perlu cek manual: Bagian pengalaman/pendidikan tidak ditemukan"
#   D  released by the reviewer (who, when, SHA-256 shown); the send then waits for the API key
#   E  "Tidak dikirim — putuskan manual", with the reviewer's note
#
# Everything runs through the real code: the participation callback queues the screening job,
# which runs INLINE here (only for this seed) so Screening::ReleaseGate prepares each text; D is
# released through an append-only AiReleaseAction the database checks (reviewer, not the job's
# consultant, digest = the version's own); E through AiReleases::Decline.
# Idempotent: when the job already exists (by title) nothing is written.
module DemoAiRelease
  TITLE = "Staf Gudang (Demo Pemeriksaan sebelum AI)".freeze

  EVIDENCE = <<~CV.freeze
    PENGALAMAN KERJA
    2018 - 2025 Admin Gudang di PT Sinar Gudang Lestari, Cikarang
    Mengelola stok 900 SKU dengan aplikasi WMS dan stock opname bulanan
    PENDIDIKAN
    D3 Manajemen Logistik, Politeknik Swadaya Bekasi, lulus 2017
    KEAHLIAN
    Microsoft Excel tingkat lanjut (VLOOKUP, pivot table)
    Memiliki SIM C dan bersedia kerja shift
  CV

  CVS = {
    "A" => "Pelamar Rilis A\nTelepon 0812-0000-1101\n#{EVIDENCE}",
    "B" => "Pelamar Rilis B\n#{EVIDENCE.sub('Mengelola stok', "Lhr. Bdg 01-02-1990\nSebagai ibu dua anak saya aktif di pengajian masjid\nMengelola stok")}",
    "C" => "Pelamar Rilis C\nSaya pekerja keras, jujur, dan siap bekerja shift di gudang mana saja.\nPernah membantu usaha keluarga selama lima tahun.",
    "D" => "Pelamar Rilis D\n#{EVIDENCE.sub('900 SKU', '1.500 SKU')}",
    "E" => "Pelamar Rilis E\n#{EVIDENCE.sub('Microsoft Excel', 'Sebagai istri dan ibu saya mahir Microsoft Excel')}"
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
                               note: "Data contoh: kalimat tentang keluarga ada di bagian keahlian; diputuskan manual.")
    end
    job
  end

  def build_job(company:, consultant:)
    job = Job.create!(title: TITLE, golongan: 2, client_company: company, location: "Cikarang", salary_min: 5_200_000,
                      salary_max: 6_200_000, consultant:)
    [["wajib", "Pendidikan minimal D3", "Ijazah D3 atau S1 di CV", nil],
     ["wajib", "Bersedia kerja shift", "Pernyataan bersedia shift", nil],
     ["sebaiknya", "Pengalaman admin gudang", "Riwayat kerja di gudang", 60],
     ["sebaiknya", "Mahir Microsoft Excel", "Keahlian Excel disebut", 40],
     ["nilai_tambah", "Memiliki SIM C", "SIM C disebut", nil]].each_with_index do |(tier, text, evidence, weight), i|
      job.requirements.create!(tier:, text:, cv_evidence: evidence, weight:, position: i + 1)
    end
    job.stages.create!(code: "S1", score_source: "ai", weight: 30, threshold: 60)
    job.stages.create!(code: "S5", score_source: "scorecard", weight: 70, threshold: 70)
    job
  end

  def apply!(job, key, cv)
    consent = ConsentTemplate.in_force or raise "no consent text in force: publish one on Pengaturan Sistem first"
    candidate = Candidate.create!(name: "Pelamar Rilis #{key}", email: "rilis.#{key.downcase}.#{job.id}@contoh.example",
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
