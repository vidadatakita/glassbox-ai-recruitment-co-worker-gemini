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
end
