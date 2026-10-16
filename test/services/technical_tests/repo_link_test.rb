require "test_helper"

# Technical test answers for programmers: a repository link (GitHub, GitLab, Bitbucket) instead of a
# file, when the version allows "repo_link". Checked by shape only, never fetched; final once sent;
# the database refuses a malformed or mixed answer even when the service is bypassed.
class TechnicalTests::RepoLinkTest < ActiveSupport::TestCase
  include TechnicalTestFactory

  setup do
    @job = technical_test_job
    @application, = applicant!(@job)
  end

  # A new approved version that accepts the given answer types.
  def allow!(types)
    params = case_version_params(@job).merge(answer_types: types, answer_types_submitted: "1", new_version_reason: "Tes programmer")
    saved = TestCases::SaveVersion.call(job: @job, actor: staff_user("consultant"), params:)
    assert saved.ok?, saved.errors.inspect
    assert TestCases::Approve.call(test_case: saved.test_case, actor: staff_user("hr_pic")).ok?
  end

  def start! = TechnicalTests::Start.call(application: @application)
  def submit(**kwargs) = TechnicalTests::SubmitAnswer.call(application: @application, **kwargs)

  test "a repository link is stored as the one final answer, with no file" do
    allow!(%w[xlsx repo_link])
    start!
    attempt = submit(url: " https://github.com/dewi/tes-backend/tree/main ")
    assert_equal ["repo_link", "https://github.com/dewi/tes-backend/tree/main"], [attempt.answer_kind, attempt.answer_url]
    assert_nil attempt.answer_blob_id
    refute attempt.answer_file.attached?
    assert_equal "attended", attempt.participation.reload.attendance
    assert_raises(TechnicalTests::SubmitAnswer::Refused) { submit(url: "https://github.com/dewi/lain") }
  end

  test "only https links to an owner/repo on the three hosts are accepted" do
    allow!(%w[repo_link])
    start!
    ["http://github.com/dewi/repo", "https://example.com/dewi/repo", "https://github.com/dewi",
     "https://github.com.evil.example/dewi/repo", "https://github.com/dewi/repo\n<script>", "javascript:alert(1)"].each do |url|
      error = assert_raises(TechnicalTests::SubmitAnswer::Refused, url) { submit(url:) }
      assert_match(/link must be a repository address/, error.message)
    end
  end

  test "a version without repo_link refuses a link; a link-only version refuses a file; never both at once" do
    start!
    assert_match(/does not accept a repository link/, assert_raises(TechnicalTests::SubmitAnswer::Refused) { submit(url: "https://github.com/dewi/repo") }.message)
    assert_match(/not both/, assert_raises(TechnicalTests::SubmitAnswer::Refused) { submit(file: answer_file, url: "https://github.com/dewi/repo") }.message)
  end

  test "a link-only version refuses a file answer" do
    allow!(%w[repo_link])
    start!
    assert_match(/asks for a repository link/, assert_raises(TechnicalTests::SubmitAnswer::Refused) { submit(file: answer_file) }.message)
  end

  # Each refused statement runs in its own savepoint: PostgreSQL aborts the whole transaction after an error.
  def refused_by_database(&)
    assert_raises(ActiveRecord::StatementInvalid) { ActiveRecord::Base.transaction(requires_new: true, &) }
  end

  test "the database refuses a malformed link, a link with file columns, and any change after sending" do
    allow!(%w[repo_link])
    attempt = start!
    refused_by_database { attempt.update_columns(answered_at: Time.current, answer_kind: "repo_link", answer_url: "https://example.com/a/b") }
    refused_by_database { attempt.reload.update_columns(answered_at: Time.current, answer_kind: "repo_link", answer_url: "https://github.com/a/b", answer_bytes: 10) }
    submit(url: "https://gitlab.com/dewi/repo")
    refused_by_database { attempt.reload.update_columns(answer_url: "https://gitlab.com/dewi/lain") }
    assert_equal "https://gitlab.com/dewi/repo", attempt.reload.answer_url
  end
end
