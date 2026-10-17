require "test_helper"

class InterviewTest < ActiveSupport::TestCase
  setup do
    @job = portal_job
    open_portal(@job)
    @application, = submit!(@job)
  end

  def interview = @interview ||= Interview.create!(job_application: @application)

  test "one interview per application" do
    interview
    assert_raises(ActiveRecord::RecordNotUnique) { Interview.create!(job_application: @application) }
  end

  test "a new interview is open, not started and has no finish reason" do
    assert interview.open?
    assert_nil interview.started_at
    assert_nil interview.due_at
  end

  test "due_at is 30 minutes after started_at" do
    interview.update!(started_at: Time.zone.parse("2026-10-17 09:00"))
    assert_equal Time.zone.parse("2026-10-17 09:30"), interview.due_at
  end

  test "a turn's answer is write-once" do
    turn = interview.turns.create!(position: 1, question: "What did you do?", asked_at: Time.current)
    turn.update!(answer_raw: "I ran a warehouse.", answer_clean: "I ran a warehouse.", answered_at: Time.current)
    assert_raises(ActiveRecord::ReadOnlyRecord) { turn.update!(answer_raw: "changed") }
  end

  test "position must be between 1 and 5" do
    assert_raises(ActiveRecord::RecordInvalid) { interview.turns.create!(position: 6, question: "q", asked_at: Time.current) }
    assert_raises(ActiveRecord::RecordInvalid) { interview.turns.create!(position: 0, question: "q", asked_at: Time.current) }
  end

  test "a position can be used once per interview" do
    interview.turns.create!(position: 1, question: "q1", asked_at: Time.current)
    assert_raises(ActiveRecord::RecordNotUnique) { interview.turns.create!(position: 1, question: "q1b", asked_at: Time.current) }
  end

  test "clean_turns skips held and unanswered turns and held_count counts the held ones" do
    now = Time.current
    interview.turns.create!(position: 1, question: "q1", answer_raw: "a", answer_clean: "a", answered_at: now, asked_at: now)
    interview.turns.create!(position: 2, question: "q2", answer_raw: "b", held: true, answered_at: now, asked_at: now)
    interview.turns.create!(position: 3, question: "q3", asked_at: now)
    assert_equal [1], interview.clean_turns.map(&:position)
    assert_equal 1, interview.held_count
  end
end
