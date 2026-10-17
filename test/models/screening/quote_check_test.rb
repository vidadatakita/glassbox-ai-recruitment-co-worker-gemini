require "test_helper"

# Blueprint §4.1 step 6: a quote not found in the extracted text (whitespace normalised only)
# makes the criterion unverified.
class Screening::QuoteCheckTest < ActiveSupport::TestCase
  EXTRACTED = "PENGALAMAN\n2017 - 2024   Admin Gudang di\nPT Logistik Makmur\nAgama: Islam".freeze
  REDACTED = "PENGALAMAN\n2017 - 2024   Admin Gudang di\nPT Logistik Makmur\n[REDACTED]".freeze

  def verified?(quote, judgement: "3") = Screening::QuoteCheck.verified?(judgement:, quote:, extracted: EXTRACTED, redacted: REDACTED)

  test "a verbatim quote is found even across line breaks and repeated spaces" do
    assert verified?("2017 - 2024 Admin Gudang di PT Logistik Makmur")
  end

  test "a fabricated, paraphrased or re-cased quote is not found" do
    refute verified?("Admin Gudang di PT Sentosa Abadi")
    refute verified?("admin gudang di pt logistik makmur")
    refute verified?("Admin gudang selama tujuh tahun")
  end

  test "a positive judgement with no quote is unverified; a negative one may have none" do
    refute verified?("", judgement: "met")
    refute verified?("  ", judgement: "2")
    assert verified?("", judgement: "not_met")
    assert verified?("", judgement: "0")
  end

  test "a negative judgement with an invented quote is unverified too" do
    refute verified?("Tidak pernah bekerja di gudang", judgement: "0")
  end

  test "a quote spanning a redaction marker is checked against the text the model saw" do
    assert verified?("PT Logistik Makmur [REDACTED]")
    refute verified?("PT Logistik Makmur [REDACTED] tambahan")
  end

  # Prompt s1-2026-10-16.4: one to three passages per criterion, each checked on its own, stored
  # joined in the one "quote" field.
  def check(entry, judgement: "3") = Screening::QuoteCheck.check(entry, judgement:, extracted: EXTRACTED, redacted: REDACTED)

  test "several passages are verified only when every one is found, and are stored joined in order" do
    both = check({ "quotes" => ["Admin Gudang di", "PT Logistik Makmur"] })
    assert both["verified"]
    assert_equal "Admin Gudang di … PT Logistik Makmur", both["quote"]
    assert_equal ["Admin Gudang di", "PT Logistik Makmur"], Screening::QuoteCheck.passages(both["quote"])
    refute check({ "quotes" => ["Admin Gudang di", "PT Sentosa Abadi"] })["verified"], "one invented passage is enough"
    refute check({ "quotes" => ["Tidak pernah bekerja di gudang"] }, judgement: "0")["verified"], "an invented passage is a defect whatever it supports"
  end

  test "empty passages and repeats carry nothing; a positive judgement needs one passage with evidence" do
    assert_equal ["PT Logistik Makmur"], Screening::QuoteCheck.passages_of({ "quotes" => ["", " PT Logistik Makmur ", "PT Logistik Makmur"] })
    refute check({ "quotes" => [] }, judgement: "met")["verified"]
    refute check({ "quotes" => ["[REDACTED]"] }, judgement: "2")["verified"], "the marker alone is not evidence (F-03)"
    assert check({ "quotes" => ["PT Logistik Makmur", "[REDACTED]"] })["verified"], "beside a real passage the marker adds nothing and hides nothing"
    assert_equal({ "quote" => "", "verified" => true }, check({ "quotes" => [] }, judgement: "0"))
  end

  test "the one-quote shape of prompts up to .3 is read the same way; an erased quote shows no passage" do
    assert check({ "quote" => "2017 - 2024 Admin Gudang di PT Logistik Makmur" })["verified"]
    refute check({ "quote" => "Admin Gudang di PT Sentosa Abadi" })["verified"]
    assert_empty Screening::QuoteCheck.passages(nil)
  end
end
