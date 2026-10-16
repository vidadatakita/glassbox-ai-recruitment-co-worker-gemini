require "test_helper"

# A stage tested outside the app (Tes psikologi, S4, "Input atau impor"): the HR PIC types the
# external score 0-100; it becomes the stage score and the threshold decision, like an interview.
class Progression::ScoreManualTest < ActiveSupport::TestCase
  include TechnicalTestFactory

  setup do
    @job = briefed_job(golongan: 4, package: 4)
    @job.update!(ad_approved_at: Time.current, ad_approved_by_id: staff_user("hr_pic").id, consultant_id: staff_user("consultant").id)
    open_portal(@job)
    @application, = applicant!(@job)
    @s4_stage = @job.stages.find_by!(code: "S4")
    @s4 = enter_stage_by_choice!(@application, @s4_stage)
    @hr = staff_user("hr_pic")
  end

  def score(value: "78,5", attendance: "attended", actor: @hr, participation: @s4, **rest)
    Progression::ScoreManual.call(participation:, actor:, attendance:, value:, **rest)
  end

  def refused(&) = assert_raises(Progression::ScoreManual::Refused, &).message

  test "a typed score becomes the stage score and the threshold decision; the stage opens" do
    assert_equal "manual_or_import", @s4_stage.score_source, "control: S4 is an input stage"
    score(value: "78,5", tested_on: "2026-10-12", note: "Hasil baik")

    entry = @s4.score_entries.current.sole
    assert_equal BigDecimal("78.5"), entry.value
    assert_equal "Hasil baik", entry.note
    assert_equal Date.new(2026, 10, 12), entry.event_at.in_time_zone("Asia/Jakarta").to_date
    assert_equal BigDecimal("78.5"), @s4.reload.current_score
    assert_equal "pass", @s4.current_decision.outcome
    assert_equal "open", @s4_stage.reload.status
  end

  test "a score below the threshold eliminates; a no-show records attendance and no score" do
    score(value: "40")
    assert_equal "eliminate", @s4.reload.current_decision.outcome

    other, = applicant!(@job)
    p = enter_stage_by_choice!(other, @s4_stage)
    score(participation: p, attendance: "no_show", value: "")
    assert_equal "no_show", p.reload.attendance
    assert_empty p.score_entries
  end

  test "refusals: wrong role, bad values, a future date, a second score, an interview or gate stage" do
    assert_match(/Only the HR owner/, refused { score(actor: staff_user("consultant")) })
    %w[abc 101 -5 7,5,5].each { |bad| assert_match(/0 to 100/, refused { score(value: bad) }, bad) }
    assert_match(/in the future/, refused { score(tested_on: (Date.current + 2).iso8601) })
    assert_match(/not recognised/, refused { score(tested_on: "13-10-2026") })
    assert_empty @s4.score_entries, "control: nothing written by a refusal"

    score(value: "70")
    assert_match(/already recorded/, refused { score(value: "80") })

    s5 = enter_stage_by_choice!(@application, @job.stages.find_by!(code: "S5"))
    assert_match(/not entered here/, refused { score(participation: s5) })
    s2 = @application.participations.joins(:stage).find_by!(stages: { code: "S2" })
    assert_match(/not entered here/, refused { score(participation: s2) })
  end
end
