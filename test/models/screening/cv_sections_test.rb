require "test_helper"

# Pengaturan Sistem "Bagian CV yang dikirim ke AI": the client chooses the CV parts; personal data
# is never one of them.
class Screening::CvSectionsTest < ActiveSupport::TestCase
  include PortalFactory

  CV = <<~CV.freeze
    DATA PRIBADI
    Nama: Rina
    RINGKASAN
    Admin gudang berpengalaman.
    PENGALAMAN KERJA
    Admin Gudang, PT Maju 2019-2024
    PORTOFOLIO
    https://rina.example
    HOBI
    Memasak
  CV

  test "the default keeps the D51 parts only; a portfolio heading ends the experience section" do
    kept = Screening::EvidenceSections.keep(CV)
    assert_includes kept, "Admin Gudang, PT Maju"
    refute_includes kept, "rina.example", "portfolio is its own part, not part of experience"
    refute_includes kept, "berpengalaman"
    refute_includes kept, "Memasak"
    refute_includes kept, "Nama: Rina"
  end

  test "the setting adds parts; personal data and unknown sections never become sendable" do
    Portal::UpdateSetting.call(key: "ai_cv_sections", value: %w[experience projects summary data_pribadi], actor: staff_user("admin"))
    assert_equal %w[experience projects summary], Screening::CvSections.enabled
    kept = Screening::EvidenceSections.keep(CV)
    assert_includes kept, "rina.example"
    assert_includes kept, "berpengalaman"
    refute_includes kept, "Nama: Rina"
    refute_includes kept, "Memasak"
    assert_equal "experience,projects,summary", SettingChange.last.new_value, "the change is recorded"
  end

  test "at least one part must stay chosen" do
    assert_raises(Portal::UpdateSetting::Invalid) { Portal::UpdateSetting.call(key: "ai_cv_sections", value: [], actor: staff_user("admin")) }
  end
end
