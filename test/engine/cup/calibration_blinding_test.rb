require "test_helper"

# Independent test pass 3: who is blinded to the AI's S1 result during calibration (ScreeningHelper#
# ai_result_blinded?), under the three roles. The code blinds "the judge": the job's consultant, or any
# HR Admin / superadmin while the job has none assigned. These tests pin the CODED behaviour per role
# and situation, and the invariant that matters for fairness: whoever may record a calibration
# judgement (Screening::JudgeCalibration) is blinded until they have judged. The spec documents read
# (user-role-16102026.md, FLOW-v2.1, BUILD-LOG) name the HR Admin as the calibrator and say nothing on
# whether a non-judging HR Admin or the HR Manager must also be blind; that question is reported, not
# encoded here.
class CupCalibrationBlindingTest < ActionView::TestCase
  include ScreeningHelper

  Stage = Struct.new(:code, :job)
  Part = Struct.new(:id, :stage)
  Row = Struct.new(:participation, :judgement)
  FakeCalibration = Struct.new(:rows, :member) do
    def applicable? = true
    def member?(_p) = member
    def digest = "invented-digest"
  end

  attr_accessor :current_user

  setup do
    @super = staff_user("superadmin")
    @admin = staff_user("hr_pic")
    @other_admin = staff_user("consultant") # a second hr_admin person
    @manager = staff_user("reviewer")
  end

  def participation(consultant: nil, code: "S1")
    job = Job.new(consultant_id: consultant&.id)
    Part.new(4242, Stage.new(code, job))
  end

  def blinded?(user, part, judged: false)
    self.current_user = user
    calibration = FakeCalibration.new([Row.new(part, judged ? :pass : nil)], false)
    Screening::Calibration.stub(:new, calibration) { ai_result_blinded?(part) }
  end

  # true when JudgeCalibration lets the user past the role and consultant checks (it then stops at the
  # stubbed "not one of the 20 calibration CVs", which proves the earlier checks passed).
  def may_judge?(user, part)
    calibration = FakeCalibration.new([], false)
    Screening::Calibration.stub(:new, calibration) do
      Screening::JudgeCalibration.call(participation: part, user:, outcome: CalibrationJudgement::OUTCOMES.keys.first)
    end
    true
  rescue Screening::JudgeCalibration::Refused => e
    # Role refusals: "…consultant…" before 13:20 on 17 Oct 2026, "Only the HR Admin judges calibration CVs." since.
    raise "unexpected refusal: #{e.message}" unless e.message.match?(/consultant|HR Admin judges|20 calibration/)

    e.message.include?("20 calibration")
  end

  # 18 Oct 2026 (Vida): the superadmin may judge calibration CVs on any vacancy, so it is blinded too
  # (before: only the assigned consultant was blinded, and the superadmin was refused the judgement).
  test "consultant assigned: that person and the superadmin are blinded, until judged" do
    part = participation(consultant: @admin)
    assert blinded?(@admin, part)
    assert_not blinded?(@admin, part, judged: true), "unblinded once judged"
    assert_not blinded?(@other_admin, part)
    assert blinded?(@super, part)
    assert_not blinded?(@super, part, judged: true), "the superadmin too is unblinded once judged"
    assert_not blinded?(@manager, part)
  end

  test "no consultant assigned: every HR Admin and the superadmin are blinded; the HR Manager is not" do
    part = participation
    assert blinded?(@admin, part)
    assert blinded?(@other_admin, part)
    assert blinded?(@super, part)
    assert_not blinded?(@manager, part)
  end

  test "a superadmin who is the job's consultant is blinded" do
    part = participation(consultant: @super)
    assert blinded?(@super, part)
    assert_not blinded?(@admin, part)
  end

  test "only S1 is blinded" do
    assert_not blinded?(@admin, participation(consultant: @admin, code: "S2"))
  end

  test "whoever may judge a calibration CV is blinded before judging (both situations, every role)" do
    [participation(consultant: @admin), participation(consultant: @super), participation].each do |part|
      [@super, @admin, @other_admin, @manager].each do |user|
        next unless may_judge?(user, part)

        assert blinded?(user, part), "#{user.role} (id #{user.id}) may judge but sees the AI result (consultant #{part.stage.job.consultant_id.inspect})"
      end
    end
    assert may_judge?(@admin, participation(consultant: @admin)), "control: the assigned consultant may judge"
    assert_not may_judge?(@other_admin, participation(consultant: @admin)), "control: another HR Admin may not"
    assert may_judge?(@super, participation(consultant: @admin)), "the superadmin may judge a vacancy with its own consultant (18 Oct 2026)"
  end
end
