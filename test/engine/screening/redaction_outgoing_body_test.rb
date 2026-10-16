require "test_helper"
require_relative "screening_engine_support"

# Blueprint §4.1 step 3 and §5.1 row 2 ("Screening on a protected attribute"), attacked with many
# Indonesian CV variants. Every assertion is on the OUTGOING REQUEST BODY the real GeminiClient
# built (FakeGemini replaces only the HTTP requester): the whole body, including the system prompt
# and the JSON schema. Every refutation has its control: the same value IS in the CV text the
# portal holds, so each refute can fail.
#
# The variant set is the test engine's own (common Indonesian CV layouts), not the builder's
# fixture. Values are chosen so they cannot occur elsewhere in the body (no bare numbers, no
# English words the system prompt itself contains).
class EngineScreeningRedactionTest < ActiveSupport::TestCase
  include ScreeningEngineSupport

  setup { @job = screening_job }

  def assert_none_leaks(cv, protected_values)
    participation, fake = screen_text!(@job, cv)
    assert_equal 1, fake.requests.size, "exactly one API call (control: the request was made)"
    stored = participation.job_application.reload.cv_text
    protected_values.each { |v| assert_includes stored, v, "control: #{v.inspect} must be in the stored CV text" }
    leaks = leaked(fake.bodies.first, protected_values)
    assert_empty leaks, "protected values reached the Gemini API request body: #{leaks.inspect}"
    fake.bodies.first
  end

  # Labelled forms the builder covered. Expected green; it is the guard the redactor mutants must
  # break.
  test "spec-list attributes in labelled Indonesian lines never reach the request body" do
    cv = <<~CV
      RINA PRATIWI
      Tempat, tanggal lahir : Bandung, 14 Februari 1996
      TTL : Semarang, 03-07-1994
      Tgl. Lahir: 09/11/1992
      Usia : 31
      Jenis Kelamin : Laki-laki
      Gender: Wanita
      Agama : Konghucu
      Agama: Katolik
      Religion: Hindu
      Status perkawinan : Belum menikah
      Status : Kawin
      Alamat : Jl. Kenanga No. 12 RT 004/RW 009, Kel. Margahayu, Bekasi
      Jalan Anggrek Raya 7, Jakarta
      RT.003/RW.011 Kelurahan Cempaka
      Bersedia ditempatkan, wanita, beragama Kristen, lajang
      Lulusan Universitas Islam Riau dan pernah aktif di Pemuda Buddha
      PENGALAMAN
      2017 - 2024 Admin Gudang di PT Logistik Makmur, Cikarang
    CV
    assert_none_leaks(cv, ["RINA", "PRATIWI", "14 Februari 1996", "03-07-1994", "09/11/1992", "Usia : 31", "Laki-laki",
                           "Wanita", "wanita", "Konghucu", "Katolik", "Hindu", "Belum menikah", "Kawin", "Kenanga",
                           "Margahayu", "Anggrek", "Cempaka", "Kristen", "lajang", "Islam", "Buddha", "RT 004/RW 009"])
  end

  # Ordinary forms of the SAME spec-listed attributes (§4.1 step 3: date of birth / age, address
  # below city level, name) that Indonesian CVs commonly use without the labels the redactor knows.
  test "spec-list attributes in common unlabelled or alternate forms never reach the request body" do
    cv = <<~CV
      CURRICULUM VITAE
      Lahir : Medan, 21 Agustus 1993
      Usia 27 tahun
      Umur 29 th
      Born in Surabaya on 2 May 1990
      Domisili : Perum Griya Asri Blok C2 No. 5, Kel. Sukamaju, Kec. Cilodong, Depok
      Profil: linkedin.com/in/rinapratiwi
      PENGALAMAN
      2017 - 2024 Admin Gudang di PT Logistik Makmur, Cikarang
    CV
    assert_none_leaks(cv, ["21 Agustus 1993", "27 tahun", "29 th", "2 May 1990", "Griya Asri", "Sukamaju", "Cilodong",
                           "rinapratiwi"])
  end

  # Builder additions (feature record §2: NIK/KTP, phone, email, suku, height/weight, blood type).
  # Labelled and common unlabelled forms that the redactor does catch.
  test "identifiers in the formats the redactor recognises never reach the request body" do
    cv = <<~CV
      NIK : 3275011203950004
      3175022309910006
      No. HP : 0812-3456-7890
      +62 821 9876 5432
      0857.5555.6666
      628129998877
      Email : RINA.PRATIWI@EXAMPLE.COM
      rina_p@mail.co.id
      Suku : Batak
      Golongan darah : AB
      Tinggi/Berat Badan : 158 cm / 49 kg
      PENGALAMAN
      2017 - 2024 Admin Gudang di PT Logistik Makmur, Cikarang
    CV
    assert_none_leaks(cv, ["3275011203950004", "3175022309910006", "0812-3456-7890", "821 9876 5432", "0857.5555.6666",
                           "628129998877", "RINA.PRATIWI@EXAMPLE.COM", "rina_p@mail.co.id", "Batak", "158 cm"])
  end

  # The same identifiers in formats that are just as common on Indonesian CVs: a KTP number
  # printed in groups of four, a +62 number with a dash, an area code in brackets, a landline.
  test "identifiers in common spaced, dashed or bracketed formats never reach the request body" do
    cv = <<~CV
      NIK 3275 0112 0395 0004
      HP/WA: +62-813-1111-2222
      Telepon rumah (0815) 3333 4444
      Telp. (021) 7654321
      Suku Jawa
      Tinggi badan 160 cm
      PENGALAMAN
      2017 - 2024 Admin Gudang di PT Logistik Makmur, Cikarang
    CV
    assert_none_leaks(cv, ["3275 0112 0395 0004", "813-1111-2222", "3333 4444", "7654321", "Suku Jawa", "160 cm"])
  end

  # Control against an over-eager redactor: what the requirements are judged on must arrive.
  # D51 re-baseline: the summary line moved from RINGKASAN (not an evidence section under D51 A, so
  # never sent) into PENGALAMAN, where the redactor still processes it.
  test "job-relevant text survives: skills, employers, years of experience, education, city of work" do
    cv = <<~CV
      Nama : Rina Pratiwi
      Agama : Islam
      PENGALAMAN
      Pengalaman 10 tahun sebagai admin gudang
      PENDIDIKAN
      D3 Manajemen Logistik, Politeknik Negeri Jakarta, lulus 2016
      PENGALAMAN KERJA
      2017 - 2024 Admin Gudang di PT Logistik Makmur, Cikarang
      Mengelola stok 1.200 SKU dengan aplikasi WMS dan stock opname bulanan.
      KEAHLIAN
      Microsoft Excel tingkat lanjut (VLOOKUP, pivot table)
      Memiliki SIM C dan bersedia kerja shift
    CV
    _, fake = screen_text!(@job, cv)
    body = body_strings(fake.bodies.first)
    ["Pengalaman 10 tahun sebagai admin gudang", "D3 Manajemen Logistik", "Politeknik Negeri Jakarta", "lulus 2016",
     "2017 - 2024 Admin Gudang di PT Logistik Makmur, Cikarang", "Mengelola stok 1.200 SKU", "Microsoft Excel tingkat lanjut",
     "Memiliki SIM C dan bersedia kerja shift"].each do |evidence|
      assert_includes body, evidence, "job evidence #{evidence.inspect} did not reach the model"
    end
    refute_includes body, "Rina", "control inside the same CV: the name was removed"
  end

  # §4.1 step 3 removes address detail BELOW city level: the city stays (feature record §2 says
  # "city kept"). Job-relevant lines that merely start with a generic label must also stay.
  test "a city in an address line and a job line starting with 'Status' are not over-redacted" do
    # D51 re-baseline: header lines are never sent (A), so both lines now sit inside the evidence
    # section, where the redactor still decides what survives.
    cv = <<~CV
      PENGALAMAN
      Alamat : Purwakarta
      Status : Karyawan tetap di PT Logistik Makmur
      2017 - 2024 Admin Gudang di PT Logistik Makmur, Cikarang
    CV
    _, fake = screen_text!(@job, cv)
    body = body_strings(fake.bodies.first)
    lost = ["Purwakarta", "Karyawan tetap"].reject { |v| body.include?(v) }
    assert_empty lost, "job-relevant or city-level text removed before it reached the model: #{lost.inspect}"
  end
end
