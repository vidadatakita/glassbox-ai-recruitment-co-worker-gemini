require "test_helper"

# Information-display review 2026-10-10: the applicant state shown to HR comes from the same
# source as the candidate's page (D1); the figures tie out (load-bearing-tests rule 20); the list
# puts who needs a person first.
class Portal::JobBoardTest < ActiveSupport::TestCase
  setup do
    @job = portal_job
    open_portal(@job)
    @rina, = submit!(@job, name: "Rina", email: "rina@uji.example")
    @budi, = submit!(@job, name: "Budi", email: "budi@uji.example")
    @sari, = submit!(@job, name: "Sari", email: "sari@uji.example")
    { @rina => "ig", @budi => "ig", @sari => "jobstreet" }.each { |a, ch| a.update_columns(channel_code: ch) }
    s1 = @job.stages.find_by!(code: "S1")
    Stages::Open.call(stage: s1)
    { @rina => 80, @budi => 75, @sari => 40 }.each do |application, score|
      participation = application.participations.find_by!(stage: s1)
      participation.update!(attendance: "attended")
      add_score(participation, score)
      decide!(participation, outcome: score >= 60 ? "pass" : "eliminate", reason_code: score >= 60 ? "at_or_above_threshold" : "below_threshold")
    end
    Stages::Close.call(stage: s1)
    @board = Portal::JobBoard.new(@job)
  end

  def row_for(application) = @board.rows.find { |r| r.application == application }

  test "an eliminated candidate is shown as eliminated to HR, exactly as on her own page (D1)" do
    staff = row_for(@sari).summary
    assert_equal ["Not passed · CV screening", "danger"], [staff.text, staff.tone]
    candidate_page = CandidateStatus.new(@sari).steps.find { |s| s.state == :not_passed }
    assert_equal "CV screening: not passed", candidate_page.label
  end

  test "per-channel counts tie out to the applications total, with shares, largest first" do
    channels = @board.per_channel
    assert_equal [["ig", 2, 67], ["jobstreet", 1, 33]], channels
    assert_equal @board.applications.size, channels.sum { |_c, n, _p| n }
  end

  test "the funnel's first stage equals the applications that entered it, and the drop is named" do
    s5 = @job.stages.find_by!(code: "S5")
    Stages::Open.call(stage: s5)
    [@rina, @budi].each { |a| enter_stage_by_choice!(a, s5) }
    board = Portal::JobBoard.new(@job)
    first, second = board.funnel
    assert_equal 3, first.entered
    assert_equal [2, 67], [second.entered, second.rate]
    assert_equal "Biggest drop: CV screening to Interview 2, 1 of 3 applicants did not continue.", board.biggest_drop
  end

  # Rina and Budi reach the same stage and Rina applied first, so only the reschedule request can
  # put Budi above her. (A first version gave Budi the furthest stage too; the "needs action" rule
  # could then be removed without the test noticing. Mutation run, 2026-10-10.)
  test "who needs a person comes first, eliminated last" do
    s5 = @job.stages.find_by!(code: "S5")
    Stages::Open.call(stage: s5)
    enter_stage_by_choice!(@rina, s5)
    participation = enter_stage_by_choice!(@budi, s5)
    participation.create_appointment!(starts_at: 1.day.from_now, ends_at: 1.day.from_now + 1.hour, mode: "onsite",
                                      place_or_link: "Lobi", contact: "Dewi", confirmation: "reschedule_requested", reschedule_reason: "Bentrok")
    order = Portal::JobBoard.new(@job).rows.map { |r| r.application.candidate.name }
    assert_equal %w[Budi Rina Sari], order
  end
end
