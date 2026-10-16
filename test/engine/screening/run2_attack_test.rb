require "test_helper"
require_relative "screening_engine_support"

# Test engine run 2 (2026-10-10, after the builder's fixes for F-01..F-08). Attacks the fixes:
# the rewritten redactor (new unlabelled forms, and over-redaction of job evidence), the job's
# catch-all for unexpected errors, gate resets, 408 retries. Run-1 files are not edited.
#
# The ONP-19 log guard here uses the engine's OWN list of protected values, independent of
# ScreeningFactory::PROTECTED (which the builder may edit). Bare numbers are not in it: a bare
# "1995" also matches a database id in a bind such as [["id", 1995]] (reproduced by the engine on
# 2026-10-10 with every sequence set to 1994: 30 hits, all ids, none date-like). Dates are caught
# by date-shaped patterns instead.
class EngineScreeningRun2RedactionTest < ActiveSupport::TestCase
  include ScreeningEngineSupport

  setup { @job = screening_job }

  def leaks_for(cv, values, name: CANDIDATE_NAME)
    participation, fake = screen_text!(@job, cv, name:)
    assert_equal 1, fake.requests.size, "control: one request"
    stored = participation.job_application.reload.cv_text
    values.each { |v| assert_includes stored, v, "control: #{v.inspect} is in the stored CV text" }
    leaked(fake.bodies.first, values)
  end

  # D51 re-baseline: every CV given to missing_for carries an evidence heading (A sends nothing else).
  def missing_for(cv, values, name: CANDIDATE_NAME)
    _, fake = screen_text!(@job, cv, name:)
    assert_equal 1, fake.requests.size, "control: the evidence text was released and sent"
    body = body_strings(fake.bodies.first)
    values.reject { |v| body.include?(v) }
  end

  # §4.1 step 3: date of birth / age. Forms common on Indonesian CVs that the second redactor misses.
  test "run 2: date of birth and age in further common forms never reach the request body" do
    cv = <<~CV
      RINA PRATIWI (28)
      Kelahiran 1994
      TTL Bandung 12-03-1995
      DOB 1996-04-21
      PENGALAMAN
      2017 - 2024 Admin Gudang di PT Logistik Makmur, Cikarang
    CV
    leaks = leaks_for(cv, ["(28)", "Kelahiran 1994", "12-03-1995", "1996-04-21"])
    assert_empty leaks, "date of birth or age reached the Gemini API request body: #{leaks.inspect}"
  end

  # §4.1 step 3: marital status. Run 1's F-06 fix stopped removing generic "Status :" lines; the
  # English words and the tax codes K/1, TK/0 (kawin / tidak kawin, number of dependants) are not
  # in the marital word list, so they now pass.
  test "run 2: marital status written as Married / Single / K/1 / TK/0 never reaches the request body" do
    cv = <<~CV
      Status : Married
      Status: Single
      Status: K/1
      Status pajak: TK/0
      PENGALAMAN
      2017 - 2024 Admin Gudang di PT Logistik Makmur, Cikarang
    CV
    leaks = leaks_for(cv, ["Married", "Single", "K/1", "TK/0"])
    assert_empty leaks, "marital status reached the Gemini API request body: #{leaks.inspect}"
  end

  # §4.1 step 3: address below city level, written the village way on line 2 of a CV header.
  test "run 2: village-style addresses (Kp./Ds./Dsn., RT 02 RW 05 without a slash) never reach the request body" do
    cv = <<~CV
      Rina Pratiwi
      Kp. Cibogo RT 02 RW 05 Ds. Ciherang Kec. Pagaden, Subang
      Kampung Rawa Bebek RT.002/RW.011, Bekasi
      Dsn. Krajan RT 002 RW 003
      PENGALAMAN
      2017 - 2024 Admin Gudang di PT Logistik Makmur, Cikarang
    CV
    leaks = leaks_for(cv, ["Cibogo", "Ciherang", "Pagaden", "Rawa Bebek", "Krajan", "RT 002 RW 003"])
    assert_empty leaks, "street/village address reached the Gemini API request body: #{leaks.inspect}"
  end

  test "run 2: forms the second redactor does catch (control set for its mutants)" do
    cv = <<~CV
      Ir. Rina Pratiwi, S.Kom
      lahir di Bandung tahun 1994
      Rina Pratiwi, 28 y.o.
      Desa Sukamaju, Kecamatan Cilodong, Depok
      Hormat saya, rina.pratiwi [at] gmail
      Profil: linkedin.com/in/rina-pratiwi-123
      Suku Batak, marga Siregar
      NIK 3275 1112 2395 1004
      TB 165 cm, BB 58 kg
      PENGALAMAN
      2017 - 2024 Admin Gudang di PT Logistik Makmur, Cikarang
    CV
    leaks = leaks_for(cv, ["Rina", "Pratiwi", "tahun 1994", "28 y.o", "Sukamaju", "Cilodong", "rina.pratiwi", "rina-pratiwi", "Batak", "3275 1112 2395 1004", "165 cm", "58 kg"])
    assert_empty leaks, leaks.inspect
  end

  # Over-redaction (run 1's F-06 class): job evidence a requirement is judged on must arrive.
  test "run 2: years of experience in brackets and loads or sizes in kg / cm survive" do
    cv = <<~CV
      PENGALAMAN KERJA
      Admin Gudang di PT Logistik Makmur (8 tahun)
      Mampu mengangkat beban 25 kg
      Mengoperasikan forklift 3 ton/2.500 kg
      Menata rak setinggi 300 cm
      2018–2023 Supervisor Gudang
    CV
    missing = missing_for(cv, ["(8 tahun)", "beban 25 kg", "2.500 kg", "300 cm", "2018–2023 Supervisor Gudang"])
    assert_empty missing, "job evidence removed before it reached the model: #{missing.inspect}"
  end

  # The name tokens run together ("analisa" from "Ana Lisa", "diantara" from "Dian Tara") are
  # removed with NO word boundary, so they cut ordinary Indonesian words out of the CV.
  test "run 2: a name run together does not cut ordinary words (Ana Lisa / Analisa, Dian Tara / Diantaranya)" do
    lost = missing_for("PENGALAMAN KERJA\nAnalisa data penjualan bulanan\nAdmin Gudang di PT Logistik Makmur", ["Analisa data penjualan"], name: "Ana Lisa")
    lost += missing_for("PENGALAMAN KERJA\nDiantaranya mengelola gudang 1.200 SKU", ["Diantaranya mengelola gudang"], name: "Dian Tara")
    assert_empty lost, "ordinary words removed because they contain the candidate's joined name: #{lost.inspect}"
  end

  test "run 2: a short name is not cut out of longer words (Ani / Manajemen) - control" do
    lost = missing_for("KEAHLIAN\nManajemen gudang dan Analisis stok", ["Manajemen gudang dan Analisis stok"], name: "Ani Sri")
    assert_empty lost
  end
end

class EngineScreeningRun2FailureTest < ActiveSupport::TestCase
  include ScreeningEngineSupport

  setup { @job = screening_job }

  def run_with(replies, &around)
    fake = FakeGemini.new(*replies)
    raised = nil
    participation = nil
    with_ai(fake) do
      participation = apply_with_cv!(@job)
      begin
        around ? around.call(-> { drain_jobs! }) : drain_jobs!
      rescue StandardError => e
        raised = e
      end
    end
    [participation.reload, fake, raised]
  end

  test "408 on every attempt: 1 + 3 retries, then Screening gagal (timeout, HTTP 408), no score" do
    p, fake, = run_with(Array.new(6) { gemini_error(408, "timeout_error") })
    assert_equal [SPEC_TRANSIENT_CALLS, "screening_failed", "timeout", "HTTP 408"],
                 [fake.requests.size, p.screening_state, p.screening_failure, p.screening_failure_detail]
    assert_equal 0, p.score_entries.count
  end

  test "408 then a good answer: 2 calls, done" do
    p, fake, = run_with([gemini_error(408, "timeout_error"), gemini_message(criteria_for(@job))])
    assert_equal [2, "done", 1], [fake.requests.size, p.screening_state, p.score_entries.count]
  end

  # The catch-all must not swallow: the error is re-raised (visible to the queue), an attempt row
  # is written, the screen says Screening gagal, and the detail is the error CLASS, never a message
  # that could carry CV text.
  test "an unexpected error before the call: re-raised, attempt row, Screening gagal, no CV text in the detail" do
    boom = Class.new(StandardError)
    stub_const = Object.const_set(:EngineRun2Boom, boom) unless Object.const_defined?(:EngineRun2Boom)
    p, fake, raised = run_with([gemini_message(criteria_for(@job))]) do |go|
      Screening::Rubric.stub(:for, ->(*) { raise EngineRun2Boom, "Rina Pratiwi Agama Islam" }) { go.call }
    end
    assert_kind_of EngineRun2Boom, raised, "the catch-all must re-raise"
    assert_equal 0, fake.requests.size
    assert_equal "screening_failed", p.screening_state
    assert_equal ["failed"], p.screening_attempts.pluck(:outcome)
    refute_includes p.screening_failure_detail.to_s, "Rina"
    refute_includes p.screening_attempts.pluck(:detail).join, "Islam"
    assert_equal 0, p.score_entries.count
    stub_const
  end

  # If the unexpected error comes AFTER the result was stored (Finalize, which writes Decisions),
  # the catch-all must not turn a stored score into "Screening gagal ... Tidak ada skor yang dibuat."
  test "an unexpected error after the result is stored never shows 'Screening gagal' over an existing score" do
    p, fake, raised = run_with([gemini_message(criteria_for(@job))]) do |go|
      Screening::Finalize.stub(:call, ->(*) { raise ActiveRecord::LockWaitTimeout, "lock" }) { go.call }
    end
    assert raised, "control: the error surfaced"
    assert_equal 1, fake.requests.size
    assert_equal 1, p.score_entries.count, "control: the result was stored before the error"
    refute_equal "screening_failed", p.screening_state,
                 "the job page says 'Screening gagal. Tidak ada skor yang dibuat.' while a ScoreEntry exists; " \
                 "'Mulai screening' would then call the API again and supersede it"
  end

  # Consent withdrawn while the request is in flight: the result must not be stored (the gate is
  # re-checked before the call only).
  test "consent withdrawn during the API call: no ScoreEntry or ScreeningResult is stored" do
    job = @job
    hook = Class.new(FakeGemini) do
      attr_accessor :before
      def call(uri, headers, body)
        before&.call
        super
      end
    end
    fake = hook.new(gemini_message(criteria_for(job)))
    participation = nil
    with_ai(fake) do
      participation = apply_with_cv!(job)
      fake.before = -> { participation.job_application.update_columns(consent_withdrawn_at: Time.current) }
      drain_jobs!
    end
    assert_equal 1, fake.requests.size, "control: the call was in flight when consent was withdrawn"
    assert_equal [0, 0], [participation.reload.score_entries.count, participation.screening_results.count],
                 "a score was stored for an application whose consent was withdrawn"
  end

  test "decided while waiting in the queue: no call, and the state returns to 'not asked'" do
    fake = FakeGemini.new
    with_ai(fake) do
      p = apply_with_cv!(@job)
      Stages::Open.call(stage: s1(@job))
      Decision.create!(participation: p, outcome: "pass", basis: "manual", reason_code: "manual", note: "uji",
                       decided_by_id: staff_user("consultant").id, decided_at: Time.current)
      drain_jobs!
      assert_equal [0, nil], [fake.requests.size, p.reload.screening_state]
    end
  end
end

class EngineScreeningRun2LogTest < ActiveSupport::TestCase
  include ScreeningEngineSupport

  # The engine's own list, independent of ScreeningFactory::PROTECTED.
  ENGINE_PROTECTED = [
    "Rina", "Pratiwi", "RINA", "rina.pratiwi", "Perempuan", "Islam", "Menikah", "Melati", "Jatiasih", "Sunda",
    "3275011203950004", "0812-3456-7890", "160 cm", "55 kg", "Agama", "Tgl Lahir",
    "Logistik Makmur", "Mengelola stok", "Microsoft Excel", "D3 Manajemen", "SIM C"
  ].freeze
  DATE_SHAPES = [/\d{1,2}-\d{1,2}-(?:19|20)\d{2}/, /(?:19|20)\d{2}-\d{2}-\d{2}(?!T|\s\d)/].freeze

  test "ONP-19 (engine's own list): a screening run writes no CV text, no personal data and no date of birth to the log" do
    job = screening_job
    io = StringIO.new
    log = ActiveSupport::Logger.new(io)
    log.level = :debug
    fake = FakeGemini.new(gemini_message(criteria_for(job)))
    participation = nil
    with_ai(fake) do
      participation = apply_with_cv!(job)
      assert_includes participation.job_application.reload.cv_text.to_s + FIXTURE_CV, "12-03-1995", "control"
      Rails.logger.broadcast_to(log)
      begin
        drain_jobs!
      ensure
        Rails.logger.stop_broadcasting_to(log)
      end
    end
    lines = io.string
    assert_equal "done", participation.reload.screening_state
    assert_match(/INSERT INTO "screening_results"/, lines, "control: the run's SQL was captured")
    leaks = ENGINE_PROTECTED.select { |v| lines.include?(v) }
    dates = DATE_SHAPES.flat_map { |re| lines.scan(re) }
    assert_empty leaks, "personal data or CV text in the log: #{leaks.inspect}"
    assert_empty dates.grep(/1995/), "a date of birth in the log: #{dates.inspect}"
  end
end
