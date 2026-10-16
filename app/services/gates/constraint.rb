module Gates
  # The database checks "the stages of a gate share one status" when the transaction COMMITS
  # (deferred constraint trigger stages_gate_status_together, migration 20261010000013). A gate
  # service asks for that check at the end of its own work, so a violation surfaces in the call that
  # caused it, and then sets the trigger back to deferred for whatever the transaction does next
  # (an immediate check would refuse the first row of the next legitimate pair update).
  module Constraint
    NAME = "stages_gate_status_together".freeze

    module_function

    def check_now!
      connection = ActiveRecord::Base.connection
      connection.execute("SET CONSTRAINTS #{NAME} IMMEDIATE")
      connection.execute("SET CONSTRAINTS #{NAME} DEFERRED")
    end
  end
end
