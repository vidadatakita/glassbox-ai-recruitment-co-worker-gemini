require "test_helper"

# MoneyText (feature 11, engine F-02/F-12/F-13/F-17): every money shape is stripped or refused; a
# number with a physical or count unit is neither. Both directions pinned here.
class MoneyTextTest < ActiveSupport::TestCase
  MONEY = ["Rp7jt", "7 jt-an", "gaji 7.5 juta", "Rp 7,5 jt/bulan", "IDR 7.500K", "7.5M", "7,5 mio", "7500 ribu", "750rb",
           "Rp.7,500,000", "US$500", "S$ 500", "€500", "7 1/2 juta", "7½ juta", "UMR + 500rb", "50 ribuan", "7 juta 500",
           "minta 7.000 (ribu)", "750 k", "seven million", "two hundred thousand", "7 million rupiah", "7mil", "7 bn",
           "tujuh juta lima ratus ribu", "Rp 7.000.000,00", "7.000.000-an", "setengah juta", "sejuta", "8000 rupiah",
           "USD 600", "Gaji 7.000.000 bulan ini", "Rp 500 kg", "$ 600 unit"].freeze
  KEPT = ["beban 500 kg", "100 SKU per jam", "ISO 9001", "nilai 85 dari 100", "kecepatan 120 wpm", "stok 1.200 karton",
          "gudang 2.000 m2", "panjang 5 m", "suhu 25 °C", "skor 85/100", "Lulus 2019, target 95%, skala 1-5", "[N12] syarat R123"].freeze

  test "every money shape is stripped or makes the text suspicious (fail closed)" do
    leaked = MONEY.reject do |shape|
      rest = MoneyText.strip("Harapan #{shape} per bulan.")
      (!rest.match?(/\d/) && !rest.match?(/\b(?:juta|ribu|ratus|rupiah|million|thousand|mil|mio)\b/i)) || MoneyText.suspicious?(rest)
    end
    assert_empty leaked
  end

  test "a number with a unit, an ISO code, a score, a year, a percentage or an id passes unchanged and is not suspicious" do
    KEPT.each do |text|
      assert_equal text, MoneyText.strip(text), text
      refute MoneyText.suspicious?(MoneyText.strip(text)), text
    end
  end

  test "a currency before a unit number, or a figure of a million or more, is money, not a unit" do
    assert_equal "[REDACTED] kg", MoneyText.strip("Rp 500 kg")
    assert_equal "Gaji [REDACTED] bulan ini", MoneyText.strip("Gaji 7.000.000 bulan ini")
    assert_equal "[REDACTED]", MoneyText.strip("7.5M"), "capital M after a number is million"
  end

  test "English number words go with their scale word, and a small digit next to a stripped figure is refused" do
    assert_equal "Harapan [REDACTED].", MoneyText.strip("Harapan seven million.")
    assert_equal "[REDACTED]", MoneyText.strip("two hundred thousand")
    rest = MoneyText.strip("Harapan 7 juta 50.")
    assert_equal "Harapan [REDACTED] 50.", rest
    assert MoneyText.suspicious?(rest), "a two-digit remainder next to [REDACTED] stops the request"
    refute MoneyText.suspicious?(MoneyText.strip("Harapan [N1] skor 50.")), "control: a small number alone is not money"
  end

  test "remaining false positives, measured: a number with a word outside the unit list stops the request" do
    ["3 kali seminggu dengan 120 kata", "kelas 400", "SAP 300"].each do |text|
      assert MoneyText.suspicious?(MoneyText.strip(text)), "#{text} is (still) refused; listed in feature record 11 part 8"
    end
  end
end
