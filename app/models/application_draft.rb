# An application in progress in the three-step form (17 Oct 2026; see the migration
# 20261017120000 for the whole design): step 1 personal details, knockout questions and consent,
# step 2 the CV, step 3 the competency test, then Submit. Found by the secret in the applicant's
# link (only its SHA-256 is stored). Never counted as an application until Submit links it to one.
class ApplicationDraft < ApplicationRecord
  belongs_to :job
  belongs_to :question_bank
  belongs_to :consent_template
  belongs_to :job_application, optional: true
  has_many :answers, class_name: "DraftAnswer", dependent: :delete_all
  has_one_attached :cv

  # Returns [draft, secret]. The secret goes into the applicant's link and nowhere else.
  def self.open!(**attributes)
    secret = SecureRandom.urlsafe_base64(32)
    [create!(**attributes, token_digest: digest(secret)), secret]
  end

  def self.digest(secret) = Digest::SHA256.hexdigest(secret.to_s)
  def self.find_by_secret(job, secret) = secret.present? ? find_by(job_id: job.id, token_digest: digest(secret)) : nil

  def submitted? = submitted_at.present?
  def test_started? = test_started_at.present?
  # The last moment an answer is accepted: the deadline plus the grace for a slow connection.
  def answer_deadline = test_due_at && (test_due_at + grace_seconds.seconds)
  def time_over?(now = Time.current) = test_started? && now > answer_deadline
  def remaining_seconds(now = Time.current) = test_started? ? [(test_due_at - now).floor, 0].max : time_limit_minutes * 60

  # The drawn questions in the order shown.
  def questions
    rows = BankQuestion.where(id: draw).index_by(&:id)
    draw.filter_map { |id| rows[id] }
  end

  def answer_for(question) = answers.detect { |a| a.bank_question_id == question.id }
  def step = cv.attached? ? 3 : 2
end
