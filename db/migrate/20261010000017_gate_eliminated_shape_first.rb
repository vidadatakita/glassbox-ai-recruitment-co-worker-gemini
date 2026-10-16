# Follow-up to 20261010000016 (F-06): a BEFORE trigger runs before CHECK constraints, so the new
# "only while the gate closes" refusal hid the clearer CHECK decisions_gate_eliminated_is_rule
# message for a manual or non-elimination row. The trigger now leaves those rows to the CHECK.
# Additive: CREATE OR REPLACE of one feature-07 function; same rules, different order.
class GateEliminatedShapeFirst < ActiveRecord::Migration[8.1]
  def up
    function = select_value("SELECT pg_get_functiondef('enforce_gate_eliminated'::regproc)")
    anchor = "IF NEW.reason_code <> 'gate_eliminated' THEN RETURN NEW; END IF;"
    raise "enforce_gate_eliminated(): anchor not found" unless function&.include?(anchor)

    execute(function.sub(anchor, "#{anchor}\n  -- The wrong shape (manual, pass, review) is refused by CHECK decisions_gate_eliminated_is_rule.\n  " \
                                 "IF NEW.basis <> 'rule' OR NEW.outcome <> 'eliminate' THEN RETURN NEW; END IF;"))
    raise "enforce_gate_eliminated() not updated" unless select_value("SELECT pg_get_functiondef('enforce_gate_eliminated'::regproc)").include?("NEW.basis <> 'rule'")
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
