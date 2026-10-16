# The answer-download link for staff views (feature 07 scoring screen, feature 08 screening report).
# Ask TechnicalTests.answer_downloadable_by? first; this only builds the signed per-user path.
module TestAnswerHelper
  def answer_link(attempt) = staff_test_attempt_answer_path(attempt, k: TechnicalTests.answer_key(current_user, attempt))
end
