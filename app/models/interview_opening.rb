# The one opening question of a vacancy's AI interview (see the migration). Written once, never changed.
class InterviewOpening < ApplicationRecord
  belongs_to :job

  validates :question, presence: true

  def readonly? = persisted? || super
end
