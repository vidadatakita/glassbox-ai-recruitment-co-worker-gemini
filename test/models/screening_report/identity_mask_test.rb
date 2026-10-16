require "test_helper"

# Engine-08 F-01: the mask applied to AI-returned text for blind viewers. Invented names only.
class ScreeningReport::IdentityMaskTest < ActiveSupport::TestCase
  Person = Struct.new(:name, :email, :phone)

  def mask = ScreeningReport::IdentityMask.new(Person.new("Kartika Gema Putri", "kartika.gp@contoh.example", "0812-7777-1234"))

  test "whole name, each word, joined handles, any case -> [nama]" do
    assert_equal "[nama], Supervisor", mask.call("Kartika Gema Putri, Supervisor")
    assert_equal "[nama] menyusun jurnal", mask.call("KARTIKA menyusun jurnal")
    assert_equal "akun [nama]", mask.call("akun kartika.gema.putri")
    assert_equal "Supervisor Akuntansi, PT Contoh Niaga", mask.call("Supervisor Akuntansi, PT Contoh Niaga"), "control: no name, unchanged"
    assert_equal "Gemar membaca", mask.call("Gemar membaca"), "whole words only: Gema is not inside Gemar"
  end

  test "email and phone shapes -> [kontak], including this candidate's own" do
    assert_equal "hubungi [kontak] atau [kontak]", mask.call("hubungi kartika.gp@contoh.example atau 0812-7777-1234")
    assert_equal "telp [kontak]", mask.call("telp +62 812 9999 0000")
    assert_equal "stok 1.200 SKU", mask.call("stok 1.200 SKU"), "control: an ordinary number stays"
  end

  test "nil stays nil" do
    assert_nil mask.call(nil)
  end
end
