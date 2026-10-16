require "test_helper"

# Engine 11 F-04/F-14, ported onto the AI Builder Cup progression design in the 2026-10-12 merge: one
# generated list of invisible characters (app/models/invisible_characters.rb) decides when a required
# note is empty. The 10-10 version also compared Ruby with a database function note_present(); that
# function belonged to the withheld feature-11 migrations, so here only Ruby and the live choice service
# are pinned.
class InvisibleCharactersTest < ActiveSupport::TestCase
  include TechnicalTestFactory

  test "every listed code point is blank, and visible characters are kept" do
    chars = InvisibleCharacters.code_points.map { |cp| [cp].pack("U") }
    assert_operator chars.size, :>, 4000, "the generated list was read"
    assert(chars.all? { |c| Progression.blank_note?(c) }, "a listed character counted as a note")
    named = [0x2003, 0x2800, 0x115F, 0x1160, 0x3164, 0xFFA0, 0x034F, 0x00AD, 0x200E, 0x200F, 0x180E, 0x200B, 0xFEFF].pack("U*")
    assert Progression.blank_note?(named)
    ["a", "0", ".", "-", "é", "中", "Belum sesuai."].each do |visible|
      refute Progression.blank_note?(visible), "control: #{visible.inspect} is a written note"
    end
  end

  test "a Tidak Lanjut whose note is only invisible characters is refused at the note field" do
    job = technical_test_job(open_gate: false)
    application, = applicant!(job, name: "Dimas Prakoso", phone: "081234567891")
    s1 = s1_of(application)
    invisible = [0x2003, 0x2800, 0x3164, 0x00AD, 0x200F, 0x200B].pack("U*") * 2

    error = assert_raises(Progression::Choose::Refused) do
      Progression::Choose.call(participation: s1, actor: staff_user("hr_pic"), choice: "tidak_lanjut",
                               seen_recommendation_id: nil, note: invisible)
    end
    assert_equal :note, error.field
    assert_nil s1.reload.progression_choice, "nothing was recorded"

    choice = Progression::Choose.call(participation: s1, actor: staff_user("hr_pic"), choice: "tidak_lanjut",
                                      seen_recommendation_id: nil, note: "Belum sesuai.")
    assert_equal "Belum sesuai.", choice.note, "control: a visible note is accepted"
  end
end
