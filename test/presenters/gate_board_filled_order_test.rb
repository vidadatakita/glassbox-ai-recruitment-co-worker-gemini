require "test_helper"

# 18 Oct 2026 (Vida): on a vacancy whose places are all filled, the gate list shows the passed applicants
# first; otherwise waiting applicants stay first (someone must act on them).
class GateBoardFilledOrderTest < ActiveSupport::TestCase
  include TechnicalTestFactory

  setup do
    @job = technical_test_job
    @owner = staff_user("owner")
  end

  def row(result) = GateBoard::Row.new(s1: Struct.new(:id).new(result == :passed ? 3 : (result == :open ? 1 : 2)), s2: nil, s1_decision: nil, s2_decision: nil, result:)

  test "waiting first while places are open; passed first once filled" do
    board = GateBoard.new(@job)
    rows = [row(:open), row(:not_passed), row(:passed)]
    order = ->(b) { rows.sort_by { |r| [b.result_order.fetch(r.result), r.s1.id] }.map(&:result) }
    refute board.filled?
    assert_equal %i[open passed not_passed], order.call(board)

    @job.update_columns(headcount: 1)
    application, = applicant!(@job, name: "Satu")
    SalaryAgreement.create!(job_application: application, agreed_amount: 8_000_000, outside_band: false, decided_by: @owner, created_at: Time.current)
    filled = GateBoard.new(@job)
    assert filled.filled?
    assert_equal %i[passed open not_passed], order.call(filled)
  end
end
