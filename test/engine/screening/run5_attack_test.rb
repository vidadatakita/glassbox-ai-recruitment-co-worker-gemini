require "test_helper"
require_relative "screening_engine_support"

# Test engine run 5 (2026-10-10, after F-25..F-30). Earlier run files are not edited.
#
# The F-27 trade-off (record 06 §2 "Run 4: context"): in EVIDENCE sections the protected WORD lists
# no longer apply; only the residual check (shapes) and the model flag remain. Exception CLAIMED by
# the record: "an address-shaped line (RT/RW, Kel./Kec., No., Jl.)" is still redacted there. Age and
# date-of-birth patterns are not listed as context-limited, so they are claimed everywhere.
# Findings are raised only where the record claims coverage; the rest is a ledger for GlassBox Team's policy
# decision (asserted as observed, so a change of behaviour is visible, not judged as a defect).
class EngineScreeningRun5Test < ActiveSupport::TestCase
  include ScreeningEngineSupport

  JOB_LINE = "Admin Gudang di PT Logistik Makmur, Cikarang, mengelola stok 1.200 SKU".freeze

  setup { @job = screening_job }

  # :blocked (nothing sent), :redacted, :sent_with_value, :too_little (held as too little text)
  def classify(cv, value)
    participation, fake = screen_text!(@job, cv)
    return(participation.screening_failure == "too_little_text" ? :too_little : :blocked) if fake.requests.empty?

    leaked(fake.bodies.first, [value]).any? ? :sent_with_value : :redacted
  end

  def in_section(heading, line) = "#{heading}\n#{line}\n#{JOB_LINE}"

  # ---- (1) claimed coverage inside evidence sections --------------------------------------------

  test "run 5 (claimed): an address-shaped line inside an evidence section is never sent with the address" do
    sent = ["Rumah saya di Kel. Jatiasih, Kec. Jatiasih, dekat gudang", "Tinggal di Jl. Melati No. 5 RT 03/RW 05 dekat gudang"]
           .select { |line| classify(in_section("PENGALAMAN KERJA", line), line[/Jatiasih|Melati/]) == :sent_with_value }
    assert_empty sent, "address below city level sent from an evidence section: #{sent.inspect}"
  end

  test "run 5 (claimed): age and birth year inside an evidence section are never sent" do
    sent = { "Umur saya 27 tahun" => "27 tahun", "Berusia 30-an, saya memimpin 5 staf" => "30-an",
             "Pada usia 45 tahun saya dipromosikan" => "45 tahun", "Saya lahir tahun 1995" => "1995" }
           .select { |line, value| classify(in_section("PENGALAMAN KERJA", line), value) == :sent_with_value }.keys
    assert_empty sent, "age or birth year sent from an evidence section: #{sent.inspect}"
  end

  test "run 5 (claimed): shapes and the name inside an evidence section are never sent" do
    sent = { "Rina Pratiwi bertanggung jawab atas stok" => "Pratiwi", "Hubungi saya di 0812-3456-7890" => "3456-7890",
             "NIK 3275011203950004" => "3275011203950004", "Lahir di Bandung 12-03-1995, mulai bekerja 2015" => "12-03-1995",
             "Agama: Islam" => "Islam" }
           .select { |line, value| classify(in_section("PENDIDIKAN", line), value) == :sent_with_value }.keys
    assert_empty sent, sent.inspect
  end

  # ---- (1) the trade-off ledger (not findings: documented residual risk, GlassBox Team's decision) -------

  LEDGER = {
    "Sebagai ibu dua anak saya terbiasa mengatur waktu" => "ibu dua anak",
    "Aktif di remaja masjid Al-Ikhlas sebagai bendahara" => "remaja masjid",
    "Suami saya mendukung saya bekerja shift" => "Suami saya",
    "Sebagai seorang muslimah saya mengenakan hijab" => "muslimah",
    "Saya beragama Kristen dan aktif di gereja" => "Kristen",
    "Sebagai janda saya menjadi tulang punggung keluarga" => "janda",
    "Saya belum menikah sehingga siap ditempatkan di mana saja" => "belum menikah",
    "Sebagai wanita saya dipercaya memimpin tim" => "wanita",
    "Saya keturunan Tionghoa dan fasih Mandarin" => "Tionghoa"
  }.freeze
  # D51 re-baseline: the body ledger (run 5: 8 of 9 sentences reached the request body) is replaced
  # by a ledger of the RELEASE SCREEN (EngineScreeningRun5ReleaseScreenTest below): under D51 B a
  # named reviewer reads every text before it is sent, so what matters is that each planted sentence
  # is visible to that reviewer and marked.

  # ---- (2) section classification ---------------------------------------------------------------

  test "run 5: personal content under an evidence heading (or its other spellings) is not sent" do
    sent = {
      "PENGALAMAN: Lahir di Bandung 12-03-1995" => "12-03-1995",
      "Pengalaman Kerja:\nLahir di Bandung 12-03-1995" => "12-03-1995",
      "WORK EXPERIENCE\nBorn in Bandung on 12 March 1995" => "12 March 1995",
      "Riwayat Karir\nSaya beragama Konghucu" => "Konghucu",
      "PENGALAMAN KERJA DAN ORGANISASI\nSaya beragama Konghucu" => "Konghucu"
    }.select { |cv, value| classify("#{cv}\n#{JOB_LINE}", value) == :sent_with_value }.keys
    assert_empty sent, sent.inspect
  end

  # Guards for the F-25 and F-26 fixes (added after mutants V02 and V04 survived the first pass).
  test "run 5: a place-date at line start dressed as a date range is still a birth date (F-25)" do
    assert_equal :blocked, classify("Bandung, 12-03-1995 – 31-12-2020\n#{JOB_LINE}", "12-03-1995")
  end

  test "run 5: an all-caps protected line keeps the personal section open to its end (F-26)" do
    body_values = { "DATA PRIBADI\nNama: Rina\nMENIKAH\nSuami saya bekerja di pabrik garmen\nHobi mengaji dan arisan\nPENGALAMAN KERJA\n#{JOB_LINE}" => ["Suami saya", "mengaji"],
                    "DATA PRIBADI\nNama: Rina\nISLAM\nAnak 2 orang, usia 3 dan 5\nPENGALAMAN KERJA\n#{JOB_LINE}" => ["Anak 2 orang"] }
    sent = body_values.flat_map { |cv, values| values.select { |v| classify(cv, v) == :sent_with_value } }
    assert_empty sent, sent.inspect
  end

  # ---- (4) F-30 at the database ----------------------------------------------------------------

  test "run 5 (F-30): the database refuses a note-less confirm for unverified and protected_attribute, accepts it otherwise" do
    fake = FakeGemini.new
    calibrated_open_job!(@job, fake)
    text = JSON.generate(criteria: criteria_for(@job, wajib: "not_met"), protected_attribute_seen: true, protected_attribute_categories: ["religion"])
    participation, = screen_text!(@job, FIXTURE_CV, replies: [gemini_message(nil, text:)], name: "Calon Catatan Run5")
    result = participation.screening_results.sole
    reviewer = staff_user("reviewer")
    decision = Decision.create!(participation:, outcome: "eliminate", basis: "rule", reason_code: "wajib_not_met",
                                decided_by_id: reviewer.id, decided_at: Time.current)
    row = { participation_id: participation.id, screening_result_id: result.id, reviewer_id: reviewer.id, verdict: "confirm",
            decision_id: decision.id, created_at: Time.current }
    %w[unverified protected_attribute].each do |reason|
      [nil, "", "   "].each do |note|
        error = refused_by_database { ScreeningReview.insert!(row.merge(reason:, note:)) }
        assert_includes error.message, "screening_reviews_flagged_confirm_has_note", "#{reason} #{note.inspect}"
      end
    end
    ScreeningReview.insert!(row.merge(reason: "elimination", note: nil)) # control: a plain elimination confirm needs no note
    assert_equal 1, ScreeningReview.count
  end

  # ---- (5) F-28 floor ---------------------------------------------------------------------------

  test "run 5 (F-28): an emptied CV whose only words are a closing sentence or filler is not sent" do
    sent = {
      "closing sentence" => "DATA PRIBADI\nNama: Rina Pratiwi\nAgama: Islam\nDemikian CV ini saya buat dengan sebenarnya",
      "four filler words" => "DATA PRIBADI\nNama: Rina Pratiwi\nPENGALAMAN\nabc def ghi jkl"
    }.select { |_, cv| %i[redacted sent_with_value].include?(classify(cv, "zzz-none")) }.keys
    assert_empty sent, "an evidence-free CV was sent to the AI to judge: #{sent.inspect}"
  end
end

class EngineScreeningRun5FlagTest < ActiveSupport::TestCase
  include ScreeningEngineSupport

  setup do
    @job = screening_job
    @fake = FakeGemini.new
    calibrated_open_job!(@job, @fake)
  end

  def reason_for(participation)
    Screening::ReviewQueue.new(@job).items.find { |i| i.participation.id == participation.id }&.reason
  end

  # (3) every flag shape once more; only exactly {seen: false, categories: []} may be trusted.
  test "run 5 (F-29): every flag shape except 'false, []' goes to the reviewer" do
    shapes = {
      "false, [religion]" => { protected_attribute_seen: false, protected_attribute_categories: ["religion"] },
      "true, []" => { protected_attribute_seen: true, protected_attribute_categories: [] },
      "true, [unknown]" => { protected_attribute_seen: true, protected_attribute_categories: ["agama"] },
      "false, nil" => { protected_attribute_seen: false, protected_attribute_categories: nil },
      "false, string" => { protected_attribute_seen: false, protected_attribute_categories: "religion" },
      "0, []" => { protected_attribute_seen: 0, protected_attribute_categories: [] },
      "missing both" => {}
    }
    wrong = shapes.each_with_index.filter_map do |(label, flag), i|
      text = JSON.generate({ criteria: criteria_for(@job) }.merge(flag))
      p, = screen_text!(@job, FIXTURE_CV, replies: [gemini_message(nil, text:)], name: "Calon Bentuk #{i}")
      label unless reason_for(p) == "protected_attribute"
    end
    assert_empty wrong, "flag shapes trusted without the reviewer: #{wrong.inspect}"
    trusted, = screen_text!(@job, FIXTURE_CV, replies: [gemini_message(criteria_for(@job))], name: "Calon Bersih")
    refute_equal "protected_attribute", reason_for(trusted), "control: 'false, []' is trusted"
  end

  # An answer outside the schema (additionalProperties false) carrying free text: it must not be
  # trusted as a clean result, and the free text must not be stored or logged.
  test "run 5: unknown extra keys in the answer are not trusted, stored or logged" do
    io = StringIO.new
    log = ActiveSupport::Logger.new(io)
    log.level = :debug
    text = JSON.generate(criteria: criteria_for(@job).map { |c| c.merge(catatan: "pelamar beragama Konghucu") },
                         protected_attribute_seen: false, protected_attribute_categories: [],
                         komentar: "Kandidat ini beragama Konghucu dan bujang")
    Rails.logger.broadcast_to(log)
    p = begin
      screen_text!(@job, FIXTURE_CV, replies: [gemini_message(nil, text:)], name: "Calon Ekstra").first
    ensure
      Rails.logger.stop_broadcasting_to(log)
    end
    stored = p.screening_results.map { |r| r.judgements.to_json + r.protected_attribute_categories.to_json }.join
    refute_includes stored, "Konghucu", "free text from the model was stored"
    refute_includes io.string, "Konghucu", "free text from the model was logged"
    if p.screening_results.any?
      assert_equal "protected_attribute", reason_for(p), "an answer outside the schema was trusted as clean"
    else
      assert_equal "screening_failed", p.screening_state
    end
  end
end

# D51 re-baseline of the run-5 ledger: each sentence planted in an experience section is shown on
# "Pemeriksaan sebelum AI" exactly as it would be sent, and its protected word is marked for the
# reviewer. Nothing is released in this test.
class EngineScreeningRun5ReleaseScreenTest < ActionDispatch::IntegrationTest
  include ScreeningEngineSupport

  setup { @job = screening_job }

  test "run 5 ledger (D51): every planted sentence is visible and marked on the release screen before anything is sent" do
    fake = FakeGemini.new
    not_visible = []
    not_marked = []
    EngineScreeningRun5Test::LEDGER.each_with_index do |(line, word), i|
      participation = with_ai(fake) do
        p = apply_with_cv!(@job, name: "Calon Ledger #{i}")
        p.job_application.update!(cv_text: "PENGALAMAN KERJA\n#{line}\n#{EngineScreeningRun5Test::JOB_LINE}", cv_text_source: "pdf", cv_text_at: Time.current)
        drain_jobs!(release: false)
        p.reload
      end
      release = AiRelease.latest_for(participation)
      assert release, "control: a version is waiting for #{line.inspect}"
      sign_in_as releaser
      get staff_ai_release_path(release)
      assert_response :success
      pre = Nokogiri::HTML(response.body).at_css("pre.release-payload")
      assert_equal release.payload_text, pre.text, "the screen shows the exact payload"
      row = pre.css(".release-line").find { |l| l.text.strip.start_with?(line.split.first) }
      visible = row && (row.text.include?(word) || row.text.include?(Screening::Redactor::MARK))
      not_visible << line unless visible
      # A word the redactor already replaced needs no mark (the reviewer sees [REDACTED]); a word
      # still present must be marked.
      not_marked << line unless row&.at_css("mark") || (row && !row.text.include?(word))
    end
    assert_equal 0, fake.requests.size, "nothing was sent while the texts wait"
    assert_empty not_visible, "planted sentences not shown to the reviewer: #{not_visible.inspect}"
    assert_empty not_marked, "planted sentences shown without a mark: #{not_marked.inspect}"
  end
end
