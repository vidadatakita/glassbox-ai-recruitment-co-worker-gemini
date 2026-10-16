require "test_helper"

# D51 A (feature 09): only experience, education, skills, certifications and training sections are
# ever sent. Every oracle below is written out from D51's wording, never read from the constants.
class Screening::EvidenceSectionsTest < ActiveSupport::TestCase
  CV = <<~CV
    CURRICULUM VITAE
    Rina Pratiwi, lahir di Bekasi, beragama Islam
    RINGKASAN
    Ibu dua anak yang teliti dan aktif di pengajian
    PENGALAMAN KERJA
    PT LOGISTIK MAKMUR
    Admin Gudang 2017 - 2024, mengelola stok 1.200 SKU
    PENDIDIKAN
    D3 Manajemen Logistik, Politeknik Negeri Jakarta
    HOBI
    Memasak untuk keluarga dan mengaji
    KEAHLIAN
    Microsoft Excel tingkat lanjut
    SERTIFIKASI
    Sertifikat K3 Umum 2021
    PELATIHAN
    Pelatihan forklift 2019
    REFERENSI
    Bapak Andi, 0812 1111 2222
  CV

  test "keeps the five evidence sections and drops the header, summary, hobbies and references" do
    kept = Screening::EvidenceSections.keep(CV)
    ["Admin Gudang 2017 - 2024", "D3 Manajemen Logistik", "Microsoft Excel tingkat lanjut", "Sertifikat K3 Umum 2021",
     "Pelatihan forklift 2019"].each { |evidence| assert_includes kept, evidence }
    ["Rina Pratiwi", "beragama Islam", "Ibu dua anak", "mengaji", "Bapak Andi", "CURRICULUM VITAE"].each do |dropped|
      refute_includes kept, dropped
    end
    # Control: the dropped values are in the input, so the refutations can fail.
    assert_includes CV, "Ibu dua anak"
  end

  test "an all-capitals employer line inside the experience section does not end it" do
    kept = Screening::EvidenceSections.keep(CV)
    assert_includes kept, "PT LOGISTIK MAKMUR"
    assert_includes kept, "mengelola stok 1.200 SKU"
  end

  test "career and licence headings (karir, lisensi) are evidence sections too" do
    kept = Screening::EvidenceSections.keep("Data diri saya\nRIWAYAT KARIR\nKasir 2019 - 2023\nLISENSI\nSIM B1 Umum\nMOTTO\nHidup untuk keluarga")
    assert_includes kept, "Kasir 2019 - 2023"
    assert_includes kept, "SIM B1 Umum"
    refute_includes kept, "Hidup untuk keluarga"
    refute_includes kept, "Data diri saya"
  end

  test "a CV without any recognisable evidence section returns nil (Perlu cek manual)" do
    assert_nil Screening::EvidenceSections.keep("Rina Pratiwi\nSaya pekerja keras dan jujur\nSiap bekerja shift")
    assert_nil Screening::EvidenceSections.keep("")
  end

  test "organisations, projects and languages are not in D51's list and are not sent" do
    kept = Screening::EvidenceSections.keep("PENGALAMAN KERJA\nAdmin 2020\nORGANISASI\nRemaja masjid Al-Ikhlas\nBAHASA\nInggris aktif")
    assert_includes kept, "Admin 2020"
    refute_includes kept, "Remaja masjid"
    refute_includes kept, "Inggris aktif"
  end
end
