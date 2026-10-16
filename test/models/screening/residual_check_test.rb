require "test_helper"

# ADR 0004 structural layer 2: after redaction, any personal-data SHAPE left means nothing is sent.
class Screening::ResidualCheckTest < ActiveSupport::TestCase
  TODAY = Date.new(2026, 10, 10)

  def findings(text, names: ["Rina Pratiwi"]) = Screening::ResidualCheck.findings(text, names:, today: TODAY)

  test "each category is detected, by shape, whatever the label" do
    {
      "Nomor: 3275 0112 0395 0004" => "id_number", "Kode 12.345.678.9-012.345" => "id_number",
      "Hubungi 0812 3456 7890" => "phone", "(021) 765-4321-9" => "phone", "+62 (813) 1111 2222" => "phone",
      "Lhr: 01-02-1990" => "birth_date", "1996-04-21" => "birth_date", "12 Maret 1995" => "birth_date", "3 Aug 1988" => "birth_date",
      "kontak rina@x.example" => "email", "Agama Kristen" => "label", "NPWP 0123" => "label", "Ttd. Pratiwi" => "name"
    }.each { |text, key| assert_includes findings(text), key, "#{text.inspect} should be found as #{key}" }
  end

  test "job evidence and redacted labels are not findings (no false alarm on a normal CV body)" do
    text = <<~CV
      NIK [REDACTED]
      Agama: [REDACTED]
      PENGALAMAN
      Maret 2017 - Mei 2024 Admin Gudang di PT Logistik Makmur (8 tahun)
      Mengelola stok 1.200 SKU, forklift 3 ton/2.500 kg, rak 300 cm
      Sertifikat K3 umum, 12 Mei 2021
      Gaji terakhir Rp 5.200.000
    CV
    assert_empty findings(text)
  end

  test "a full date is a birth date only for years 1950 to 15 years before today" do
    assert_includes findings("01-02-2011"), "birth_date"
    assert_empty findings("01-02-2012")
    assert_empty findings("01-02-1949")
  end

  # F-24: work context vs birth context.
  test "a full date in work context is not a birth date; next to lahir or alone after a place it is" do
    assert_empty findings("01-06-2009 s/d 31-12-2014 Staf Gudang di PT Sinar Abadi")
    assert_empty findings("Operator Forklift SIO, terbit 12 Maret 2010")
    assert_includes findings("Bandung, 12-03-1995"), "birth_date"
    assert_includes findings("Bandung, 12/03/95"), "birth_date"
    assert_includes findings("Bandung, 12 Mar '95"), "birth_date"
    assert_includes findings("Bandung, Maret 1995"), "birth_date"
    assert_includes findings("Lahir 12-03-1995 di kota kecil"), "birth_date"
    assert_includes findings("Catatan 12-03-1995"), "birth_date", "ambiguous stays a finding (fail closed)"
  end

  # F-23: the evidence floor.
  test "an emptied text is too little to judge; one job line is enough" do
    assert Screening::ResidualCheck.too_little_text?("[REDACTED]\nRIWAYAT KARIR\n[REDACTED]")
    refute Screening::ResidualCheck.too_little_text?("RIWAYAT KARIR\n2017 - 2024 Admin Gudang di PT Logistik Makmur")
  end
end
