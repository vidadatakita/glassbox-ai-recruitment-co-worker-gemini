require "test_helper"

# Blueprint §4.1 step 3 / §5.1 row 2: protected attributes are removed before any text leaves.
# These are the unit-level cases; test/services/screening/outgoing_request_test.rb asserts the
# same on the real outgoing HTTP body.
class Screening::RedactorTest < ActiveSupport::TestCase
  include ScreeningFactory

  def redact(text, names: [CANDIDATE_NAME]) = Screening::Redactor.call(text, names:).text

  test "the fixture CV loses every protected value and keeps every piece of evidence" do
    out = redact(FIXTURE_CV)
    PROTECTED.each { |value| refute_includes out, value, "#{value.inspect} survived redaction" }
    EVIDENCE.each { |value| assert_includes out, value, "evidence #{value.inspect} was removed" }
  end

  test "control: the raw fixture CV does contain every protected value (the assertions above can fail)" do
    PROTECTED.each { |value| assert_includes FIXTURE_CV, value }
  end

  test "Indonesian label variants, each on its own line" do
    {
      "Tgl lahir: 1 Januari 1990" => "1990", "Tanggal Lahir : 01/01/1990" => "1990", "TTL : Bandung, 2 Mei 1988" => "1988",
      "Tempat, Tanggal Lahir: Solo, 3 Juni 1992" => "1992", "Umur: 27" => "27", "Status Pernikahan : Belum Menikah" => "Belum",
      "Status Perkawinan: Kawin" => "Kawin", "Jenis kelamin: Laki-laki" => "Laki", "Agama: Kristen Protestan" => "Kristen",
      "Alamat Domisili : Jl. Kenanga 4, Depok" => "Kenanga", "No. KTP: 3201010101900001" => "3201010101900001",
      "Golongan Darah : O" => "Darah", "WhatsApp: +62 812 1111 2222" => "1111"
    }.each do |line, value|
      out = redact("Ringkasan\n#{line}\nPengalaman gudang 3 tahun")
      refute_includes out, value, "#{line.inspect} kept #{value.inspect}"
      assert_includes out, "Pengalaman gudang 3 tahun"
    end
  end

  test "English label variants" do
    out = redact("Date of Birth: 4 April 1991\nReligion: Catholic\nMarital Status: Married\nGender: Female\nAddress: 5 Mawar Street, Bogor\nAge: 33")
    %w[1991 Catholic Married Female Mawar 33].each { |v| refute_includes out, v }
  end

  test "two-column layouts lose the protected half of the line" do
    out = redact("Pendidikan: S1 Akuntansi    Agama: Hindu\nPosisi terakhir: Supervisor   Status pernikahan: Cerai")
    assert_includes out, "Pendidikan: S1 Akuntansi"
    assert_includes out, "Posisi terakhir: Supervisor"
    refute_match(/Hindu|Cerai|Agama/i, out)
  end

  test "unlabelled values: religion and gender words, ages in brackets, emails, phones, NIK, street lines" do
    out = redact("Rina (29 tahun), wanita muslimah\nLulusan Universitas Islam Bandung\nKontak rina@x.example / 081311112222\n3201010101900001\nJl. Anggrek 9 RT 01/RW 02\nBekasi")
    %w[29 wanita muslimah Islam rina@x.example 081311112222 3201010101900001 Anggrek RT].each { |v| refute_includes out, v }
    assert_includes out, "Bekasi", "city level stays (§4.1 step 3: address detail BELOW city level)"
  end

  test "the candidate's name goes in full and by its parts, and only as whole words" do
    out = redact("RINA PRATIWI\nReferensi: Ibu Pratiwi\nPrinadi", names: ["Rina Pratiwi"])
    refute_match(/rina|pratiwi/i, out.sub("Prinadi", ""))
    assert_includes out, "Prinadi", "a word that merely contains a name part is not touched"
  end

  test "a document with nothing protected comes back unchanged" do
    text = "PENGALAMAN\n2019 - 2023 Operator forklift di gudang dingin\nSertifikat SIO forklift"
    assert_equal text, redact(text, names: [])
  end

  # Test engine run 1, F-01/F-02 follow-up: forms beyond the engine's own variants.
  test "a NIK printed in groups of four is removed whole, not only the part a phone rule happens to hit" do
    # The third line has no label the redactor knows: only the NIK shape can catch it.
    out = redact("NIK 3175 2209 9123 6145\nKTP: 3175-2209-9123-6145\nNo. identitas 3175 2209 9123 6145\nPengalaman gudang 3 tahun", names: [])
    refute_match(/3175|2209|9123|6145/, out)
    assert_includes out, "Pengalaman gudang 3 tahun"
  end

  test "profile links and handles carrying the name, and the name anywhere in the text" do
    out = redact("instagram.com/rina.pratiwi99\ngithub.com/rpratiwi\n@rina_pratiwi\nReferensi dari Bu Pratiwi Sari")
    refute_match(/rina|pratiwi|rpratiwi/i, out)
  end

  test "address labels keep the city and drop everything below it" do
    out = redact("Tempat tinggal : Gg. Mawar 3, Kec. Tambun Selatan, Kabupaten Bekasi\nAlamat KTP: Komp. Griya Indah Blok A1, Karawang")
    refute_match(/Mawar|Tambun|Griya|A1/, out)
    assert_includes out, "Kabupaten Bekasi"
    assert_includes out, "Karawang"
  end

  test "ages in other units and dates of birth without a label word next to the date" do
    out = redact("Usia: 27 thn\nUmur 31\n(25 yo)\nLahir di Medan pada 21 Agustus 1993\nBorn: 02/05/1990")
    refute_match(/27|31|25|1993|1990|Medan/, out)
  end

  test "a section the CV titles as personal data is dropped whole, up to the next heading (ADR 0004)" do
    out = redact("RINGKASAN\nAdmin gudang 7 tahun\nDATA PRIBADI\nHobi: memancing di Situ Gintung\nGol. darah O, suka kopi\nPENGALAMAN\nAdmin Gudang di PT Logistik Makmur")
    refute_match(/Gintung|memancing|darah/, out)
    assert_includes out, "Admin gudang 7 tahun"
    assert_includes out, "Admin Gudang di PT Logistik Makmur"
  end

  test "NPWP in its printed format is removed (addition beyond the spec list)" do
    out = redact("NPWP: 12.345.678.9-012.345\nNo NPWP 123456789012345\nKode pajak 12.345.678.9-012.345", names: [])
    refute_match(/12\.345|123456789012345/, out)
  end

  # F-23: a personal section ends at ANY heading-shaped line, not only at a known heading.
  test "a personal section ends at an unknown all-caps, numbered or colon heading" do
    ["RIWAYAT KARIR", "3. Jejak Karier", "Riwayat Karier:"].each do |heading|
      out = redact("DATA PRIBADI\nNasrani\n#{heading}\n2017 - 2024 Admin Gudang di PT Logistik Makmur")
      assert_includes out, "Admin Gudang di PT Logistik Makmur", "#{heading.inspect} did not end the personal section"
      refute_includes out, "Nasrani"
    end
  end

  test "the candidate's name in capitals inside a personal section does not end it" do
    out = redact("DATA PRIBADI\nRINA PRATIWI\nBandung, 12-03-1995\nPENGALAMAN\nAdmin Gudang")
    refute_includes out, "12-03-1995"
  end

  # F-27: protected WORD lists apply in personal context only; evidence sections keep their words.
  test "protected words are removed in the header but kept in an evidence section" do
    out = redact("Wanita, Islam, lajang\nPENGALAMAN KERJA\nKasir di Toko Gadis Mart\nPENDIDIKAN\nS1 Universitas Islam Indonesia", names: [])
    refute_match(/Wanita|lajang/, out.lines.first)
    refute_includes out.lines.first, "Islam"
    assert_includes out, "Kasir di Toko Gadis Mart"
    assert_includes out, "S1 Universitas Islam Indonesia"
  end

  # GlassBox Team, 16 Oct 2026: English pronouns and religion words go everywhere, evidence
  # sections included. Mutant per class: delete the PRONOUN_EN / RELIGION_EN line in #redact_words.
  test "English gender pronouns are removed inside an evidence section, one by one" do
    %w[he she his her him hers himself herself He SHE].each do |word|
      out = redact("WORK EXPERIENCE\n2019 - present  Supervisor at PT Mitra, #{word} was promoted after two years", names: [])
      refute_match(/\b#{word}\b/, out, "#{word} survived in an evidence section")
      assert_includes out, "was promoted after two years"
    end
    result = Screening::Redactor.call("WORK EXPERIENCE\nShe led the team and her reports praised him", names: [])
    assert_equal 3, result.counts[:gender]
    assert_equal "WORK EXPERIENCE\n#{Screening::Redactor::MARK} led the team and #{Screening::Redactor::MARK} reports praised #{Screening::Redactor::MARK}", result.text
  end

  test "English religion words are removed inside an evidence section, one by one" do
    %w[Christian catholic Protestant Muslim Islamic Buddhist Hindu church mosque temple].each do |word|
      out = redact("EDUCATION\nBachelor of Accounting, #{word} University of Indonesia, graduated 2014", names: [])
      refute_match(/\b#{word}\b/i, out, "#{word} survived in an evidence section")
      assert_includes out, "Bachelor of Accounting"
      assert_includes out, "University of Indonesia, graduated 2014"
    end
    assert_equal 1, Screening::Redactor.call("EDUCATION\nChristian University", names: []).counts[:religion]
  end

  test "control: merit words and names that merely contain a pronoun or religion word survive" do
    line = "WORK EXPERIENCE\nPromoted to supervisor after the bank reconciliation project with Hermawan, Shelly and Templeton at Church Street branch"
    out = redact(line, names: [])
    %w[Promoted supervisor reconciliation Hermawan Shelly Templeton Street branch].each { |w| assert_includes out, w }
    refute_includes out, "Church", "a bare religion word is removed even as part of a place name (over-redact rather than under-redact)"
  end

  test "a street address with RT/RW is removed even inside an evidence section" do
    out = redact("PENGALAMAN KERJA\nAdmin di kantor Gang Mawar 3 RT 02 RW 05, Bekasi", names: [])
    refute_match(/Mawar|RT 02/, out)
  end

  # F-26: an all-caps protected word is personal content, not a heading, so the section goes on.
  test "a protected word in capitals inside a personal section does not end it" do
    %w[ISLAM MENIKAH WANITA].each do |word|
      out = redact("DATA PRIBADI\n#{word}\nHobi memancing di Situ Gintung\nPENGALAMAN\nAdmin Gudang", names: [])
      refute_includes out, "Gintung", "#{word} ended the personal section"
      assert_includes out, "Admin Gudang"
    end
  end
end
