require "test_helper"
require_relative "screening_engine_support"

# Test engine run 3 (2026-10-10), after ADR 0004 (personal sections dropped whole; ResidualCheck
# refuses to send when a personal-data SHAPE remains). The property under attack is the one that
# costs money (§5.1 row 2): a protected value is NEVER "sent with the value". Each case runs alone
# through the real pipeline (portal application, job, gem-built request) and is classified as
#   :blocked          nothing sent (zero HTTP requests): fail closed worked
#   :redacted         sent, value absent from the whole request body
#   :sent_with_value  sent, value present: the failure
# Forms are invented by the engine on purpose to miss the redactor's patterns.
class EngineScreeningRun3FailClosedTest < ActiveSupport::TestCase
  include ScreeningEngineSupport

  EVIDENCE = "PENGALAMAN KERJA\n2017 - 2024 Admin Gudang di PT Logistik Makmur, Cikarang\nMengelola stok 1.200 SKU dengan aplikasi WMS.\n".freeze

  setup { @job = screening_job }

  def classify(line, value, name: CANDIDATE_NAME)
    fake = FakeGemini.new(gemini_message(criteria_for(@job)))
    participation = nil
    with_ai(fake) do
      participation = apply_with_cv!(@job, name:)
      participation.job_application.update!(cv_text: "#{line}\n#{EVIDENCE}", cv_text_source: "pdf", cv_text_at: Time.current)
      drain_jobs!
    end
    return :blocked if fake.requests.empty?

    leaked(fake.bodies.first, [value]).any? ? :sent_with_value : :redacted
  end

  def assert_never_sent_with_value(cases, category)
    results = cases.to_h { |line, value| [line, classify(line, value)] }
    sent = results.select { |_, r| r == :sent_with_value }.keys
    assert_empty sent, "#{category}: sent to the Gemini API WITH the value (#{sent.size} of #{cases.size}): #{sent.inspect}"
  end

  test "run 3 / §4.1 step 3 religion: synonyms and spellings are never sent with the value" do
    assert_never_sent_with_value([["Nasrani", "Nasrani"], ["Kong Hu Cu", "Kong Hu Cu"], ["Kepercayaan: Kejawen", "Kejawen"],
                                  ["Kristen Protestan", "Protestan"], ["Muslimah berhijab", "Muslimah"], ["Beragama Budha", "Budha"]], "religion")
  end

  test "run 3 / §4.1 step 3 gender: colloquial and abbreviated forms are never sent with the value" do
    assert_never_sent_with_value([["Cewek, suka tantangan", "Cewek"], ["Cowok, suka tantangan", "Cowok"], ["L/P : P", "L/P : P"],
                                  ["Seorang ibu rumah tangga yang ingin kembali bekerja", "ibu rumah tangga"]], "gender")
  end

  test "run 3 / §4.1 step 3 marital status: synonyms are never sent with the value" do
    assert_never_sent_with_value([["Bujang", "Bujang"], ["Sudah berkeluarga", "berkeluarga"], ["Tanggungan: istri dan 2 anak", "istri dan 2 anak"],
                                  ["Status: TK", "Status: TK"], ["Duda 1 anak", "Duda"], ["Janda", "Janda"], ["Belum kawin", "Belum kawin"]], "marital status")
  end

  test "run 3 / §4.1 step 3 address below city level: village and housing forms are never sent with the value" do
    assert_never_sent_with_value([["Lingk. Sukamaju RT 3", "Sukamaju"], ["Dukuh Krajan, Desa Wonorejo", "Wonorejo"],
                                  ["Tinggal di Gang Kelinci 3, Bekasi", "Gang Kelinci"], ["Asrama Brimob Kelapa Dua, Depok", "Asrama Brimob"],
                                  ["Kp. Cibogo RT 02 RW 05", "Cibogo"]], "address")
  end

  test "run 3 / §4.1 step 3 date of birth and age: short and partial dates are never sent with the value" do
    assert_never_sent_with_value([["Bandung, 12/03/95", "12/03/95"], ["Bandung, 12 Mar '95", "12 Mar '95"], ["Bandung, Maret 1995", "Maret 1995"],
                                  ["Usia 27 thn", "27 thn"], ["Tanggal lahir: dua belas Maret 1995", "Maret 1995"]], "date of birth / age")
  end

  test "run 3 / §4.1 step 3 name: variants of the candidate's own name are never sent with the value" do
    assert_never_sent_with_value([["RINA P.", "RINA"], ["R. Pratiwi", "Pratiwi"], ["IG: @rina.pratiwi95", "rina"]], "name")
  end

  # Beyond the spec list (builder's own additions): ethnicity and body measures.
  test "run 3 / builder additions: ethnicity and body measures are never sent with the value" do
    assert_never_sent_with_value([["Etnis Tionghoa", "Tionghoa"], ["Keturunan Tionghoa", "Tionghoa"], ["Orang Batak asli", "Batak"],
                                  ["Berdarah Minang", "Minang"], ["Tinggi 158, berat 49", "158"]], "ethnicity / body")
  end

  test "run 3 / shapes the residual check owns: id numbers, phones, emails, full birth dates are never sent" do
    assert_never_sent_with_value([["Nomor identitas 3275 0112 0395 0004", "0395"], ["Hubungi 0812 3456 789", "3456"],
                                  ["Surat: ina.p95(at)gmail(dot)com", "ina.p95"], ["Bandung, 12-03-1995", "12-03-1995"],
                                  ["Born on March 12th, 1995", "1995"]], "shapes")
  end
end

class EngineScreeningRun3ResidualTest < ActiveSupport::TestCase
  include ScreeningEngineSupport

  test "run 3: ResidualCheck finds each shape, and nothing in clean job text (control)" do
    today = Date.new(2026, 10, 10)
    {
      "id_number" => "Nomor 3275 0112 0395 0004", "phone" => "Hubungi 0812 3456 7890", "birth_date" => "Bekasi, 12-03-1995",
      "email" => "kirim ke ina.p95@contoh.example", "label" => "Agama Islam", "name" => "Salam, Pratiwi"
    }.each do |category, text|
      assert_includes Screening::ResidualCheck.findings(text, names: ["Rina Pratiwi"], today:), category, text
    end
    clean = "PENGALAMAN KERJA\n2017 - 2024 Admin Gudang di PT Logistik Makmur\nKontrak 01-02-2019 s/d 31-12-2022\nLulus Maret 2010"
    assert_equal [], Screening::ResidualCheck.findings(clean, names: ["Rina Pratiwi"], today:)
  end

  # D51 re-baseline: a residual finding no longer ends in screening_failed/personal_data; the version
  # waits flagged and CANNOT be released (feature 09 §2 "C moved"). The date sits inside the evidence
  # section, because header lines are no longer sent at all (A).
  test "run 3: an unlabelled birth date the redactor misses is not sent; the version is flagged by category and cannot be released" do
    participation, fake = screen_text!(screening_job, "PENGALAMAN KERJA\nBekasi, 12-03-1995\n2017 - 2024 Admin Gudang di PT Logistik Makmur")
    assert_equal 0, fake.requests.size
    assert_equal "awaiting_release", participation.screening_state
    release = AiRelease.latest_for(participation)
    assert_includes release.residual_categories, "birth_date"
    error = assert_raises(AiReleases::Refused) do
      AiReleases::Release.call(release:, user: releaser, confirmed: "1", seen_sha256: release.payload_sha256)
    end
    assert_match(/Personal data is still detected/, error.message)
    refute_includes release.residual_categories.join, "1995"
    refute_includes participation.screening_failure_detail.to_s, "1995"
    assert_equal 0, participation.score_entries.count
  end
end

class EngineScreeningRun3SectionsTest < ActiveSupport::TestCase
  include ScreeningEngineSupport

  setup { @job = screening_job }

  def screen(cv)
    participation, fake = screen_text!(@job, cv)
    [participation, fake, fake.requests.empty? ? nil : body_strings(fake.bodies.first)]
  end

  # Layer 1 drops a personal section up to the next KNOWN heading. A CV whose next heading is not in
  # the list (RIWAYAT KARIR, "PENGALAMAN KERJA DAN ORGANISASI") loses everything after "Data Pribadi".
  # Acceptable only if it is not then sent as an empty CV for the AI to judge.
  test "run 3: a personal section followed by an unknown heading never sends an evidence-free CV" do
    cvs = {
      "RIWAYAT KARIR" => "DATA PRIBADI\nNama: Rina Pratiwi\nTTL: Bekasi, 12-03-1995\nRIWAYAT KARIR\n2017 - 2024 Admin Gudang di PT Logistik Makmur\nKEAHLIAN TAMBAHAN\nMicrosoft Excel tingkat lanjut, bersedia kerja shift",
      "PENGALAMAN KERJA DAN ORGANISASI" => "Data Pribadi\nNama: Rina Pratiwi\nPENGALAMAN KERJA DAN ORGANISASI\n2017 - 2024 Admin Gudang di PT Logistik Makmur\nPENDIDIKAN DAN PELATIHAN\nD3 Manajemen Logistik"
    }
    bad = cvs.filter_map do |label, cv|
      _, fake, body = screen(cv)
      next if fake.requests.empty? # flagged instead of sent: acceptable
      "#{label}: sent without its evidence" unless body.include?("Admin Gudang di PT Logistik Makmur")
    end
    assert_empty bad, "the whole CV after 'Data Pribadi' was dropped and the remainder sent to the AI: #{bad.inspect}"
  end

  test "run 3: numbered and colon headings are recognised; job sections titled Kontak/Contact are kept (control)" do
    _, _, body = screen("1. DATA PRIBADI:\nNama: Rina Pratiwi\nNasrani\nBujang\n2. PENGALAMAN KERJA\n2017 - 2024 Admin Gudang di PT Logistik Makmur")
    refute_nil body
    refute_includes body, "Nasrani", "unlabelled values inside a titled personal section are dropped with it"
    refute_includes body, "Bujang"
    assert_includes body, "Admin Gudang di PT Logistik Makmur"
    _, _, body = screen("PENGALAMAN\nKontak dengan pelanggan\nMenangani 50 keluhan pelanggan per hari\nContact center experience\n3 tahun di call center PT Telekom")
    refute_nil body
    ["Kontak dengan pelanggan", "Menangani 50 keluhan", "Contact center experience", "3 tahun di call center"].each { |e| assert_includes body, e }
  end
end

class EngineScreeningRun3FalsePositiveTest < ActiveSupport::TestCase
  include ScreeningEngineSupport

  # Five invented, realistic CVs for an admin/warehouse job. Personal data sits in a titled
  # section (layer 1). Each is screened through the real pipeline; "blocked" = Perlu cek manual.
  REALISTIC = {
    "fresh graduate 2022" => <<~CV,
      DATA PRIBADI
      Nama: Rina Pratiwi
      PENDIDIKAN
      D3 Manajemen Logistik, Politeknik Negeri Jakarta, lulus 2022
      PENGALAMAN KERJA
      Agustus 2022 - sekarang Admin Gudang di PT Logistik Makmur, Cikarang
      KEAHLIAN
      Microsoft Excel tingkat lanjut, bersedia kerja shift
    CV
    "10 years, month-year periods" => <<~CV,
      DATA PRIBADI
      Nama: Rina Pratiwi
      PENGALAMAN KERJA
      Maret 2014 - sekarang Admin Gudang di PT Logistik Makmur, Cikarang
      Kontrak 01-02-2019 s/d 31-12-2022 sebagai koordinator stok
      SERTIFIKASI
      Sertifikat K3 Umum, 14 Mei 2015
    CV
    "15 years, full-date contract periods" => <<~CV,
      DATA PRIBADI
      Nama: Rina Pratiwi
      PENGALAMAN KERJA
      01-06-2009 s/d 31-12-2014 Staf Gudang di PT Sinar Abadi, Bekasi
      01-01-2015 s/d sekarang Supervisor Gudang di PT Logistik Makmur, Cikarang
    CV
    "references with office phone and email" => <<~CV,
      DATA PRIBADI
      Nama: Rina Pratiwi
      PENGALAMAN KERJA
      2016 - 2024 Admin Gudang di PT Logistik Makmur, Cikarang
      REFERENSI
      Bpk. Hendra Gunawan, HRD PT Logistik Makmur, (021) 555-1234, hrd@logistikmakmur.co.id
    CV
    "certificate dated before 2011" => <<~CV,
      DATA PRIBADI
      Nama: Rina Pratiwi
      PENGALAMAN KERJA
      2012 - 2024 Admin Gudang di PT Logistik Makmur, Cikarang
      SERTIFIKASI
      Operator Forklift SIO, Kemnaker, terbit 12 Maret 2010
    CV
  }.freeze

  setup { @job = screening_job }

  test "run 3: residual-check false alarms on realistic CVs (rate reported; a work date is not a birth date)" do
    blocked = REALISTIC.select do |_, cv|
      _, fake = screen_text!(@job, cv)
      fake.requests.empty?
    end.keys
    rate = "#{blocked.size} of #{REALISTIC.size}"
    # A work or certificate date from an adult's career is not a date of birth: blocking it sends a
    # clean CV to "Perlu cek manual". Expected 0 of 5.
    assert_empty blocked, "false 'Perlu cek manual' on #{rate} realistic CVs: #{blocked.inspect}"
  end

  # A name that is also a common word: the CV must still be screenable (never blocked forever),
  # and the employer/evidence word should not be wiped (reported separately if it is).
  test "run 3: a candidate named 'Budi Jaya' or 'Sinta Kerja' is not blocked forever" do
    cases = {
      "Budi Jaya" => "PENGALAMAN KERJA\n2017 - 2024 Admin Gudang di PT Sinar Jaya Abadi, Jayapura\nBersedia kerja shift",
      "Sinta Kerja" => "PENGALAMAN KERJA\n2017 - 2024 Admin Gudang, Kerja2 lapangan dan kerja-sama tim\nBersedia kerja shift"
    }
    blocked = cases.select do |name, cv|
      _, fake = screen_text!(@job, cv, name:)
      fake.requests.empty?
    end.keys
    assert_empty blocked, "CVs blocked as 'Perlu cek manual' only because a name word is an ordinary word: #{blocked.inspect}"
  end
end

class EngineScreeningRun3FixesTest < ActiveSupport::TestCase
  include ScreeningEngineSupport

  setup { @job = screening_job }

  # F-14: after a finalize error the score stands and "Mulai screening" retries Finalize only.
  test "run 3 (F-14): after a finalize error, Mulai screening never calls the API again" do
    fake = FakeGemini.new(gemini_message(criteria_for(@job)), gemini_message(criteria_for(@job)))
    participation = nil
    with_ai(fake) do
      participation = apply_with_cv!(@job)
      Screening::Finalize.stub(:call, ->(*) { raise ActiveRecord::LockWaitTimeout, "lock" }) do
        assert_raises(ActiveRecord::LockWaitTimeout) { drain_jobs! }
      end
      assert_equal ["done", "finalize"], [participation.reload.screening_state, participation.screening_failure]
      Screening::Start.call(@job)
      Screening::Start.call(@job)
      drain_jobs!
    end
    assert_equal 1, fake.requests.size, "the retry of a finalize error called the API again"
    assert_equal [1, 1], [participation.reload.score_entries.count, participation.screening_results.count]
  end

  # F-15: consent withdrawn during the call -> nothing stored, and the CV is not left as "done"
  # or "Dalam antrean".
  test "run 3 (F-15): consent withdrawn during the call leaves no score and no queued/done state" do
    hook = Class.new(FakeGemini) do
      attr_accessor :before
      def call(uri, headers, body)
        before&.call
        super
      end
    end
    fake = hook.new(gemini_message(criteria_for(@job)))
    participation = nil
    with_ai(fake) do
      participation = apply_with_cv!(@job)
      fake.before = -> { participation.job_application.update_columns(consent_withdrawn_at: Time.current) }
      drain_jobs!
    end
    assert_equal 1, fake.requests.size
    assert_equal [0, 0], [participation.reload.score_entries.count, participation.screening_results.count]
    refute_includes %w[done queued], participation.screening_state
  end
end
