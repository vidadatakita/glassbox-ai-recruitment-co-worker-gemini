require "test_helper"
require Rails.root.join("db/seeds/demo_screening_report").to_s

# Feature 08 demo seed: invented, idempotent, and it shows SPEC §3 exactly (A/B/C) plus every
# label and test state. Read through the same board the screen and the xlsx use.
class DemoScreeningReportSeedTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def seed!
    set_retention
    publish_consent
    DemoScreeningReport.run(company:, hr: staff_user("hr_pic"), consultant: staff_user("consultant"), reviewer: staff_user("reviewer"))
  end

  test "SPEC §3 rows, every label and state, both visibility states; a second run writes nothing" do
    open_job, closed_job = seed!
    board = ScreeningReportBoard.new(open_job, staff_user("consultant"))
    by = board.rows.index_by { |r| r.candidate.name.delete_prefix("Sample Candidate ") }
    spec = { "A" => [4, "82", :passed, [7_000_000, 8_000_000], "direkomendasikan"],
             "B" => [4, "58", :failed_test, [6_000_000, 7_000_000], "pertimbangkan_terbatas"],
             "C" => [5, "91", :passed, [14_000_000, 18_000_000], "over_qualified"] }
    spec.each do |key, (band, test, gate, salary, label)|
      row = by.fetch(key)
      assert_equal [band, test, gate, salary, label],
                   [row.band, ScreeningReport::Text.test(row.test), row.gate,
                    [row.application.expected_salary_min, row.application.expected_salary_max], row.label_key], key
    end
    assert_equal ScreeningReport::Labels::ORDER.sort, board.rows.map(&:label_key).uniq.sort, "every label shown"
    assert_equal %i[awaiting_review expired in_progress not_started scored].sort, board.rows.map { |r| r.test.state }.uniq.sort
    assert_equal %i[failed_cv failed_test open passed], board.rows.map(&:gate).uniq.sort
    assert_equal %i[above below not_given within], board.rows.map(&:budget).uniq.sort
    # The live progression design (AI Builder Cup, kept in the 2026-10-12 merge) has no strict entry
    # rule, so the seed gives A an Interview 1 appointment on the open job, as before feature 11.
    # If the strict rule is ported, A's appointment moves to the closed job again (see stash@{0}).
    assert by.fetch("A").appointment && by.fetch("A").recommendation
    assert_nil by.fetch("B").appointment, "an absent interview appointment is shown too"
    assert_nil by.fetch("B").recommendation
    assert_equal ["Bekasi", nil], [by.fetch("A").application.domicile_city, by.fetch("D").application.domicile_city], "D54 both states"
    approved = board.rows.map { |r| board.narrative_approval(r.result).present? }
    assert_equal [false, true], approved.uniq.sort_by { |v| v ? 1 : 0 }, "narratives approved and AI draft both present"
    refute ScreeningReport::Visibility.new(open_job, staff_user("hr_pic")).names?
    assert ScreeningReport::Visibility.new(closed_job, staff_user("hr_pic")).names?
    closed = ScreeningReportBoard.new(closed_job, staff_user("hr_pic"))
    assert_includes closed.rows.map { |r| r.test.state }, :gate_eliminated
    counts = [Job, ScreeningResult, ScoreEntry, Decision, TestAttempt, ScreeningLabelConfirmation].map(&:count)
    seed!
    assert_equal counts, [Job, ScreeningResult, ScoreEntry, Decision, TestAttempt, ScreeningLabelConfirmation].map(&:count)
    assert ScreeningResult.where(participation: board.rows.map(&:s1)).all? { |r| r.model_id == DemoScreeningReport::MODEL_ID }
  end
end
