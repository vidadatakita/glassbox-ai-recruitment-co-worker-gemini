# Rows are never changed after insert (blueprint §2.1; expensive failure #4). The database
# refuses UPDATE and DELETE as well (migration MakeScoringRecordsAppendOnly); this makes the
# application fail early and clearly instead of reaching the trigger.
module AppendOnly
  extend ActiveSupport::Concern

  def readonly?
    persisted? || super
  end
end
