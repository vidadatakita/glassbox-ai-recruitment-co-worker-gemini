require "test_helper"
require_relative "screening_engine_support"

# Test engine run 4 (2026-10-10), after the F-16..F-24 fixes and the model-side third line
# (prompt s1-2026-10-10.2, protected_attribute_seen / protected_attribute_categories, migration
# 20261010000011). Earlier run files are not edited.
#
# Note on the factory change: ScreeningFactory#gemini_message now adds the two flag fields to
# every scripted answer. The run-1..3 tests that build answers with `gemini_message(criteria)` now
# send a flag "false / []"; the tests that pass `text:` (malformed cases, the "score 99" case) send
# no flag at all, which the code reads as "seen, other". No earlier test asserts on the flag, so
# none of them changes meaning; the flag's own paths are attacked here with explicit JSON.
class EngineScreeningRun4PipelineTest < ActiveSupport::TestCase
  include ScreeningEngineSupport

  setup { @job = screening_job }

  def outcome(cv, name: CANDIDATE_NAME)
    participation, fake = screen_text!(@job, cv, name:)
    [participation, fake.requests.empty? ? nil : body_strings(fake.bodies.first)]
  end

  # (1) The evidence floor counts letters, so filler passes it.
  test "run 4: a CV emptied by redaction is not sent when what is left is filler or headings" do
    sent = { "20+ letters of filler" => "DATA PRIBADI\nNama: Rina Pratiwi\nPENGALAMAN\nabcdefghij klmnopqrstu" }
           .select { |_, cv| outcome(cv)[1] }.keys
    assert_empty sent, "an evidence-free CV was sent to the AI to judge: #{sent.inspect}"
  end

  test "run 4: headings-only and emptied CVs are held back as too little text (control for the floor)" do
    {
      "only headings" => "PENGALAMAN KERJA\nPENDIDIKAN\nKEAHLIAN\nSERTIFIKASI\nREFERENSI\nBAHASA",
      "a closing line only" => "DATA PRIBADI\nNama: Rina Pratiwi\nAgama: Islam\nDemikian CV ini"
    }.zip(%w[too_little_text no_evidence_section]).each do |(label, cv), kind|
      participation, body = outcome(cv)
      assert_nil body, "#{label} was sent"
      # D51 re-baseline: a CV with no evidence section is "no_evidence_section" (A), not too_little_text.
      assert_equal kind, participation.screening_failure, label
    end
  end

  test "run 4: a short real CV body is still screened (control for the floor)" do
    _, body = outcome("PENGALAMAN KERJA\n2017 - 2024 Admin Gudang di PT Logistik Makmur")
    refute_nil body
    assert_includes body, "Admin Gudang di PT Logistik Makmur"
  end

  # (2) F-24's work-context rule: a birth date line that carries a work word is treated as work.
  test "run 4: a date of birth dressed as work context is never sent with the date" do
    sent = {
      "Bandung, 12-03-1995 – sekarang" => "Bandung, 12-03-1995 – sekarang\nPENGALAMAN KERJA\nAdmin Gudang di PT Logistik Makmur Cikarang",
      "12-03-1995 (kontrak)" => "RINA PRATIWI\n12-03-1995 (kontrak)\nPENGALAMAN KERJA\nAdmin Gudang di PT Logistik Makmur Cikarang",
      "Lahir 12-03-1995 s/d sekarang" => "Lahir 12-03-1995 s/d sekarang\nPENGALAMAN KERJA\nAdmin Gudang di PT Logistik Makmur Cikarang"
    }.select { |_, cv| (body = outcome(cv)[1]) && body.include?("12-03-1995") }.keys
    assert_empty sent, "a date of birth reached the Gemini API request body: #{sent.inspect}"
  end

  test "run 4: work and certificate dates are not mistaken for a birth date (control)" do
    _, body = outcome("PENGALAMAN KERJA\n01-06-2009 s/d 31-12-2014 Staf Gudang PT Sinar Abadi\nSERTIFIKASI\nOperator Forklift SIO, Bandung, 12 Maret 2010")
    refute_nil body, "blocked as Perlu cek manual"
    assert_includes body, "01-06-2009 s/d 31-12-2014"
  end

  # (3) Section end: an all-caps protected word inside a personal section ends the section early;
  # what follows is handled by word patterns only.
  test "run 4: an all-caps protected word inside a personal section does not end it early and leak the rest" do
    leaks = []
    {
      "ISLAM" => ["DATA PRIBADI\nNama: Rina\nISLAM\nTempat tinggal Dukuh Krajan\nPENGALAMAN KERJA\nAdmin Gudang di PT Logistik Makmur Cikarang", "Krajan"],
      "MENIKAH" => ["BIODATA\nMENIKAH\nTinggal di Perum Griya, Blok C\nPENGALAMAN KERJA\nAdmin Gudang di PT Logistik Makmur Cikarang", "Griya"],
      "RINA PRATIWI" => ["DATA PRIBADI\nRINA PRATIWI\nDomisili Kampung Rawa Bebek\nPENGALAMAN KERJA\nAdmin Gudang di PT Logistik Makmur Cikarang", "Rawa Bebek"]
    }.each do |label, (cv, value)|
      _, body = outcome(cv)
      leaks << "#{label}: #{value}" if body&.include?(value)
    end
    assert_empty leaks, "personal-section content after an all-caps line reached the request body: #{leaks.inspect}"
  end

  # (6) Word lists added for F-16..F-21 against job evidence.
  test "run 4: new protected-word lists do not cut job evidence" do
    lines = ["Mengelola biaya kos karyawan proyek", "Membersihkan gang way kapal", "Proyek Dana Desa Kabupaten Bogor",
             "Sales fashion hijab di Zoya", "Kasir di Toko Gadis Mart", "Penerjemah bahasa Tionghoa", "Lingkungan kerja K3",
             "Gang supervisor shift malam", "Kawin silang ternak sapi", "Pengelola asrama karyawan"]
    _, body = outcome("PENGALAMAN KERJA\n#{lines.join("\n")}\nAdmin Gudang di PT Logistik Makmur")
    refute_nil body
    lost = lines.reject { |l| body.include?(l) }
    assert_empty lost, "job evidence cut by the new word lists (#{lost.size} of #{lines.size}): #{lost.inspect}"
  end
end

class EngineScreeningRun4FlagTest < ActiveSupport::TestCase
  include ScreeningEngineSupport

  setup do
    @job = screening_job
    @fake = FakeGemini.new
    calibrated_open_job!(@job, @fake)
  end

  def flagged(seen, categories, name)
    text = JSON.generate(criteria: criteria_for(@job), protected_attribute_seen: seen, protected_attribute_categories: categories)
    participation, = screen_text!(@job, FIXTURE_CV, replies: [gemini_message(nil, text:)], name:)
    participation
  end

  def reason_for(participation)
    Screening::ReviewQueue.new(@job).items.find { |i| i.participation.id == participation.id }&.reason
  end

  test "run 4: every untrusted flag shape goes to the reviewer and stores no echoed value" do
    cases = {
      "true, empty list" => [true, []], "unknown category" => [true, ["agama"]], "value echoed as category" => [true, ["Islam"]],
      "flag as string" => ["true", ["religion"]], "flag missing" => [nil, nil]
    }
    io = StringIO.new
    log = ActiveSupport::Logger.new(io)
    Rails.logger.broadcast_to(log)
    results = begin
      cases.each_with_index.to_h { |(label, (seen, cats)), i| [label, flagged(seen, cats, "Calon Bendera #{i}")] }
    ensure
      Rails.logger.stop_broadcasting_to(log)
    end
    results.each do |label, p|
      result = p.screening_results.sole
      assert_equal "protected_attribute", reason_for(p), label
      assert_nil p.reload.current_decision, "#{label}: decided without the reviewer"
      result.protected_attribute_categories.each do |c|
        assert_includes protected_categories, c, "#{label}: a non-category value stored: #{c.inspect}"
      end
    end
    refute_match(/categories=[^\n]*(Islam|agama)/i, io.string, "an echoed value reached the log")
  end

  # A model that lists categories but says "not seen" contradicts itself; fail safe means the
  # reviewer looks.
  test "run 4: protected_attribute_seen false WITH categories is not trusted" do
    p = flagged(false, ["religion"], "Calon Kontradiksi")
    assert_equal "protected_attribute", reason_for(p), "a self-contradicting flag was trusted and the result may be auto-decided"
  end

  test "run 4: the reviewer note is required for a protected-attribute result by the service" do
    p = flagged(true, ["religion"], "Calon Catatan")
    result = p.screening_results.sole
    reviewer = staff_user("reviewer")
    error = assert_raises(Screening::Review::Refused) { Screening::Review.call(result:, reviewer:, verdict: "confirm") }
    assert_includes error.message, "A note is required"
    assert_equal 0, ScreeningReview.count
  end

  test "run 4: the database refuses a note-less confirm of a protected-attribute result" do
    p = flagged(true, ["religion"], "Calon Catatan DB")
    result = p.screening_results.sole
    reviewer = staff_user("reviewer")
    # Database: a confirm row for a protected_attribute reason with no note, pointing at a
    # non-manual decision (a path that bypasses the service).
    decision = Decision.create!(participation: p, outcome: "pass", basis: "threshold", reason_code: "at_or_above_threshold",
                                decided_by_id: reviewer.id, decided_at: Time.current)
    refused_by_database do
      ScreeningReview.insert!({ participation_id: p.id, screening_result_id: result.id, reviewer_id: reviewer.id,
                                verdict: "confirm", reason: "protected_attribute", note: nil, decision_id: decision.id,
                                created_at: Time.current })
    end
  end

  # (5) The widened CHECK still refuses everything else.
  test "run 4: the widened screening_reviews reason CHECK refuses every other value" do
    p = flagged(true, ["religion"], "Calon Cek")
    result = p.screening_results.sole
    reviewer = staff_user("reviewer")
    decision = Decision.create!(participation: p, outcome: "pass", basis: "manual", reason_code: "screening_review_confirmed",
                                note: "uji", decided_by_id: reviewer.id, decided_at: Time.current)
    row = { participation_id: p.id, screening_result_id: result.id, reviewer_id: reviewer.id, verdict: "confirm",
            note: "uji", decision_id: decision.id, created_at: Time.current }
    ["", "PROTECTED_ATTRIBUTE", "protected attribute", "religion", "other", "manual"].each do |bad|
      error = refused_by_database { ScreeningReview.insert!(row.merge(reason: bad)) }
      assert_includes error.message, "screening_reviews_reason", bad.inspect
    end
    ScreeningReview.insert!(row.merge(reason: "protected_attribute")) # control: the new value is accepted
    assert_equal 1, ScreeningReview.count
  end

  private

  def protected_categories = Screening::AiClient::PROTECTED_CATEGORIES
end
