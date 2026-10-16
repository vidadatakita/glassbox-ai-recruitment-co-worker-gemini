# A candidate's objection to an S1 elimination (E21, D33; UU 27/2022 Pasal 10(1)). A person
# reviews it and the answer is shown on the status page. One open objection per participation.
class Objection < ApplicationRecord
  OUTCOMES = { "upheld" => "Objection accepted", "not_upheld" => "Objection not accepted" }.freeze

  belongs_to :participation
  delegate :job, to: :participation # the record's company is its job's (BaseController#org_find)

  validates :text, :received_at, presence: true
  validates :outcome, inclusion: { in: OUTCOMES.keys }, allow_nil: true

  scope :open, -> { where(answered_at: nil) }

  def answered? = answered_at.present?

  class Refused < StandardError; end

  # D40 (maker != checker): whoever took part in the decisions on this participation may not judge
  # the objection against them. Every decision counts, not only the current one.
  def answer!(user:, outcome:, answer:, now: Time.current)
    raise Refused, "This objection has already been answered." if answered?
    raise Refused, "Choose an outcome and write an answer." if answer.to_s.strip.empty? || !OUTCOMES.key?(outcome)
    if participation.decisions.where(decided_by_id: user.id).exists?
      raise Refused, "This objection must be answered by someone else: you took part in deciding this stage's result."
    end

    update!(outcome:, answer: answer.strip, answered_by_id: user.id, answered_at: now)
  end
end
