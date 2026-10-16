# Builders for the feature 06 (S1 AI screening) tests. Every name, address and CV is invented.
#
# The Gemini API is STUBBED AT THE HTTP BOUNDARY: FakeGemini is installed as Screening::AiClient
# .http_override, the seam inside #send_http, so the request body the tests inspect is the one the
# real GeminiClient built and would have sent. No test ever reaches the network: the AI is only
# switched on with FAKE_KEY, and FAKE_KEY is only ever used with FakeGemini installed.
module ScreeningFactory
  FAKE_KEY = "test-not-a-real-key".freeze
  FAKE_MODEL = "gemini-3.8-flash".freeze

  # The HTTP double. Each #call pops the next scripted reply: a Hash (JSON body, HTTP 200), an
  # [status, Hash] pair, or an exception class/instance to raise (as Net::HTTP would).
  class FakeGemini
    attr_reader :requests

    def initialize(*replies)
      @replies = replies
      @requests = []
    end

    def push(*replies) = @replies.concat(replies)

    # Same contract as the real request in AiClient#send_http: [status, raw body].
    def call(uri, headers, body)
      @requests << { url: uri.to_s, headers:, body: }
      reply = @replies.shift
      raise "FakeGemini: no scripted reply left (request #{@requests.size})" if reply.nil?
      raise reply if reply.is_a?(Exception) || (reply.is_a?(Class) && reply <= Exception)

      status, json = reply.is_a?(Array) ? reply : [200, reply]
      [status, JSON.generate(json)]
    end

    def bodies = requests.map { |r| r[:body] }
    def parsed_bodies = bodies.map { |b| JSON.parse(b) }
  end

  # Runs the block with the AI switched on (a fake key, so the Gemini API route is taken) and
  # FakeGemini as the transport.
  def with_ai(fake)
    Screening::AiClient.http_override = fake
    Screening::Config.stub(:api_key, FAKE_KEY) { yield fake }
  ensure
    Screening::AiClient.http_override = nil
  end

  # A Gemini generateContent response carrying the given criteria as the JSON answer text. The
  # first part is a thought part, which the client must skip. protected: categories the model
  # reports as seen (ADR 0004 line 3); empty = flag false. finish: "STOP" is complete,
  # "MAX_TOKENS" is cut off, anything else (SAFETY, ...) is a refusal.
  def gemini_message(criteria, model: FAKE_MODEL, finish: "STOP", text: nil, protected: [])
    answer = text || JSON.generate({ criteria:, protected_attribute_seen: protected.any?, protected_attribute_categories: protected })
    { candidates: [{ content: { role: "model", parts: [{ text: "", thought: true }, { text: answer }] }, finishReason: finish }],
      usageMetadata: { promptTokenCount: 1200, candidatesTokenCount: 300 }, modelVersion: model }
  end

  # The prompt was blocked before any answer (promptFeedback.blockReason); the client reports the
  # reason, lower-cased, as the refusal category.
  def refusal_message(category: "PROHIBITED_CONTENT")
    { promptFeedback: { blockReason: category } }
  end

  # A Google API error body with the given HTTP status, as the fake's [status, body] pair.
  def gemini_error(status, type)
    [status, { error: { code: status, status: type, message: "test" } }]
  end

  # The user-message text of a recorded request, and the system prompt: the two places candidate
  # text could travel, read from the Gemini request shape in one place.
  def request_user_text(parsed_body) = parsed_body.dig("contents", 0, "parts", 0, "text")
  def request_system_text(parsed_body) = parsed_body.dig("systemInstruction", "parts", 0, "text")
  def request_schema(parsed_body) = parsed_body.dig("generationConfig", "responseJsonSchema")

  # The fixture CV (Indonesian format) carrying every attribute the redactor must remove, and the
  # evidence the requirements below ask for. Each protected VALUE is listed in PROTECTED so the
  # tests assert on values, not only on labels.
  CANDIDATE_NAME = "Rina Pratiwi".freeze
  FIXTURE_CV = <<~CV.freeze
    CURRICULUM VITAE
    Nama Lengkap : Rina Pratiwi
    Tempat/Tgl Lahir : Bekasi, 12-03-1995
    Usia : 31 tahun
    Jenis Kelamin : Perempuan
    Agama : Islam
    Status : Menikah
    Alamat : Jl. Melati Raya No. 17 RT 03/RW 05, Kel. Jatiasih, Bekasi
    NIK : 3275011203950004
    No. HP : 0812-3456-7890
    Email : rina.pratiwi@contoh.example
    Suku : Sunda
    Tinggi/Berat Badan : 160 cm / 55 kg
    PENDIDIKAN
    D3 Manajemen Logistik, Politeknik Negeri Jakarta, lulus 2016
    PENGALAMAN KERJA
    2017 - 2024 Admin Gudang di PT Logistik Makmur, Cikarang
    Mengelola stok 1.200 SKU dengan aplikasi WMS dan stock opname bulanan.
    KEAHLIAN
    Microsoft Excel tingkat lanjut (VLOOKUP, pivot table)
    Memiliki SIM C dan bersedia kerja shift
  CV
  # "03-1995", not the bare year "1995": a bare 4-digit year also matches database ids in the SQL
  # log once a long parallel run passes id 1995 (seen in the test engine's log test, 2026-10-10),
  # a false positive that says nothing about redaction.
  PROTECTED = [
    "Rina", "Pratiwi", "12-03-1995", "03-1995", "31 tahun", "Perempuan", "Islam", "Menikah", "Melati", "RT 03",
    "Jatiasih", "3275011203950004", "0812-3456-7890", "rina.pratiwi@contoh.example", "Sunda", "160 cm",
    "Agama", "Jenis Kelamin", "Tgl Lahir", "Raya No. 17"
  ].freeze
  # Evidence that must SURVIVE redaction (control: an over-eager redactor that deletes everything
  # would pass the protected-value assertions while making screening useless).
  EVIDENCE = [
    "D3 Manajemen Logistik", "Admin Gudang di PT Logistik Makmur", "Mengelola stok 1.200 SKU",
    "Microsoft Excel tingkat lanjut"
  ].freeze

  # Minimal one-page PDF with a real text layer (Helvetica, WinAnsi). ASCII text only.
  def pdf_with_text(text)
    lines = text.split("\n")
    stream = +"BT /F1 9 Tf 12 TL 40 800 Td "
    lines.each { |l| stream << "(#{l.gsub(/[\\()]/) { |c| "\\#{c}" }}) Tj T* " }
    stream << "ET"
    build_pdf(stream)
  end

  # A PDF whose only content is a filled rectangle: no text layer, like a scanned image.
  def pdf_without_text = build_pdf("0 0 0 rg 40 400 300 300 re f")

  def build_pdf(content)
    objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
      "<< /Length #{content.bytesize} >>\nstream\n#{content}\nendstream"
    ]
    out = +"%PDF-1.4\n"
    offsets = objects.each_with_index.map do |obj, i|
      offset = out.bytesize
      out << "#{i + 1} 0 obj\n#{obj}\nendobj\n"
      offset
    end
    xref = out.bytesize
    out << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n"
    offsets.each { |o| out << format("%010d 00000 n \n", o) }
    out << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
    out
  end

  # A job ready for screening: portal job (S1 "ai" threshold 60, S5), consultant assigned, and a
  # rubric of two wajib, two sebaiknya (60/40) and one nilai tambah requirement.
  def screening_job(consultant: staff_user("consultant"))
    job = portal_job
    job.update!(consultant:)
    [
      ["wajib", "Pendidikan minimal D3", "Ijazah D3 atau S1 di CV", nil],
      ["wajib", "Bersedia kerja shift", "Pernyataan bersedia shift", nil],
      ["sebaiknya", "Pengalaman admin gudang", "Riwayat kerja di gudang", 60],
      ["sebaiknya", "Mahir Microsoft Excel", "Keahlian Excel disebut", 40],
      ["nilai_tambah", "Memiliki SIM C", "SIM C disebut", nil]
    ].each_with_index do |(tier, text, evidence, weight), i|
      job.requirements.create!(tier:, text:, cv_evidence: evidence, weight:, position: i + 1)
    end
    open_portal(job)
    job
  end

  def s1(job) = job.stages.find_by!(code: "S1")
  def rubric_keys(job) = Screening::Rubric.for(job).criteria.map(&:key)

  # Criteria answering every requirement of the job. ratings: { tier => judgement } defaults; quotes
  # are taken verbatim from FIXTURE_CV so the quote check passes unless a test overrides one.
  def criteria_for(job, wajib: "met", sebaiknya: "3", nilai_tambah: "2", quotes: {})
    default_quotes = {
      "wajib" => "D3 Manajemen Logistik", "sebaiknya" => "Admin Gudang di PT Logistik Makmur",
      "nilai_tambah" => "Memiliki SIM C"
    }
    Screening::Rubric.for(job).criteria.map do |c|
      judgement = { "wajib" => wajib, "sebaiknya" => sebaiknya, "nilai_tambah" => nilai_tambah }.fetch(c.tier)
      quote = quotes.fetch(c.key) { %w[not_met 0].include?(judgement) ? "" : default_quotes.fetch(c.tier) }
      { id: c.key, judgement:, quote: }
    end
  end

  # Submits one application with a CV PDF through the real portal service. Returns the S1
  # participation.
  def apply_with_cv!(job, cv_text: FIXTURE_CV, name: CANDIDATE_NAME, email: nil, pdf: nil)
    email ||= "#{name.parameterize}-#{SecureRandom.hex(3)}@uji.example"
    application, = submit!(job, name:, email:, cv: pdf_upload(pdf || pdf_with_text(cv_text)))
    application.participations.find_by!(stage: s1(job))
  end

  def run_screening_jobs = perform_enqueued_jobs

  # Feature 09 (D51 B): every CV now stops at "Menunggu pemeriksaan" until a named reviewer
  # releases the exact text. This releases every clean held text through the REAL service
  # (AiReleases::Release: the reviewer's tick, the digest the reviewer saw), as `reviewer` (a fresh
  # reviewer who is not the job's consultant by default). A version with residual-check findings
  # is NOT released (the service refuses it, as on screen); it stays held. Returns the actions.
  # run_screening_jobs is deliberately unchanged: the feature-06 engine calls it, and changing what
  # it does would change engine outcomes by the builder's hand.
  def release_held!(reviewer: nil)
    reviewer ||= staff_user("reviewer")
    Participation.where(screening_state: "awaiting_release").filter_map do |p|
      release = AiRelease.latest_for(p)
      next if release.nil? || !release.pending? || release.residual?

      AiReleases::Release.call(release:, user: reviewer, confirmed: "1", seen_sha256: release.payload_sha256)
    end
  end

  # Runs the screening jobs, releases every clean held text as a reviewer, and runs the jobs again
  # (the released text is then sent). The D51 equivalent of run_screening_jobs.
  def screen_and_release!(reviewer: nil)
    perform_enqueued_jobs
    release_held!(reviewer:)
    perform_enqueued_jobs
  end

  # Brings a job through calibration: 20 applications screened by the fake AI as passes, and the
  # consultant judging each the same way (0 disagreements). Returns the participations.
  # release: true (feature 09, D51 B) lets a reviewer release each held text, as the pipeline now
  # requires; the default stays false so the feature-06 engine's calls behave as written.
  def calibrate!(job, fake, consultant: job.consultant, judge: ->(_i) { "pass" }, release: false)
    participations = Array.new(Screening::Calibration::SIZE) do |i|
      fake.push(gemini_message(criteria_for(job)))
      apply_with_cv!(job, name: "Calon Uji #{i + 1}")
    end
    release ? screen_and_release! : run_screening_jobs
    participations.each_with_index do |p, i|
      Screening::JudgeCalibration.call(participation: p, user: consultant, outcome: judge.call(i))
    end
    participations
  end
end
