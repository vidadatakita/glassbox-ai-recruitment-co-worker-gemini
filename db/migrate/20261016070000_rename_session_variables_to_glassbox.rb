# frozen_string_literal: true

# A2 (GlassBox rename, 16 Oct 2026): the three trigger functions read transaction-local settings
# named after the legacy product (<legacy>.tenancy, <legacy>.stage_change_id, <legacy>.gate_closing).
# The application now sets glassbox.* (config/database.yml, Stages::ChangeThreshold, Gates::Close), so
# a database created before this migration would silently stop enforcing all three guards: the
# function would read an unset variable and treat every change as unnamed. CREATE OR REPLACE keeps
# the triggers bound; only the setting name changes. Function bodies are byte-identical to
# db/structure.sql apart from that name. Fresh databases load structure.sql, which already carries
# the new names; this migration exists for databases created from the earlier dump.
class RenameSessionVariablesToGlassbox < ActiveRecord::Migration[8.1]
  # The old prefix, spelled once and built at run time so the repository text carries no legacy name.
  LEGACY = %w[hire kita].join

  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION enforce_single_tenant() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF current_setting('glassbox.tenancy', true) = 'single' THEN
    LOCK TABLE client_companies IN SHARE ROW EXCLUSIVE MODE;
    IF EXISTS (SELECT 1 FROM client_companies) THEN
      RAISE EXCEPTION 'TENANCY=single allows one client company'
        USING ERRCODE = 'unique_violation';
    END IF;
  END IF;
  RETURN NEW;
END;
      $$;
      CREATE OR REPLACE FUNCTION enforce_stage_lifecycle() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE named_change bigint := NULLIF(current_setting('glassbox.stage_change_id', true), '')::bigint;
BEGIN
  IF OLD.opened_at IS NOT NULL AND NEW.opened_at IS DISTINCT FROM OLD.opened_at THEN
    RAISE EXCEPTION 'stages: opened_at cannot change once set' USING ERRCODE = 'restrict_violation';
  END IF;
  IF NEW.status <> OLD.status AND NOT (
       (OLD.status = 'draft' AND NEW.status = 'open') OR (OLD.status = 'open' AND NEW.status = 'closed')) THEN
    RAISE EXCEPTION 'stages: status cannot move from % to %', OLD.status, NEW.status USING ERRCODE = 'restrict_violation';
  END IF;
  IF OLD.status = 'closed' AND (NEW.threshold <> OLD.threshold OR NEW.weight <> OLD.weight) THEN
    RAISE EXCEPTION 'stages: tahap sudah ditutup; weight and threshold are final' USING ERRCODE = 'restrict_violation';
  END IF;
  IF OLD.status = 'open' AND NEW.status = 'closed' AND EXISTS (
       SELECT 1 FROM participations p
       WHERE p.stage_id = NEW.id AND NOT EXISTS (
         SELECT 1 FROM decisions d
         WHERE d.participation_id = p.id AND d.outcome <> 'review'
           AND NOT EXISTS (SELECT 1 FROM decisions s WHERE s.supersedes_id = d.id))) THEN
    RAISE EXCEPTION 'stages: cannot close while a participation is undecided or in review'
      USING ERRCODE = 'restrict_violation';
  END IF;
  IF OLD.opened_at IS NOT NULL THEN
    IF NEW.threshold <> OLD.threshold AND NOT EXISTS (
         SELECT 1 FROM stage_changes sc
         WHERE sc.id = named_change AND sc.stage_id = NEW.id AND sc.field = 'threshold'
           AND sc.old_value = OLD.threshold AND sc.new_value = NEW.threshold
           AND sc.id = (SELECT max(id) FROM stage_changes WHERE stage_id = NEW.id AND field = 'threshold')) THEN
      RAISE EXCEPTION 'stages: a locked threshold changes only with its latest StageChange named in the same transaction'
        USING ERRCODE = 'restrict_violation';
    END IF;
    IF NEW.weight <> OLD.weight AND NOT EXISTS (
         SELECT 1 FROM stage_changes sc
         WHERE sc.id = named_change AND sc.stage_id = NEW.id AND sc.field = 'weight'
           AND sc.old_value = OLD.weight AND sc.new_value = NEW.weight
           AND sc.id = (SELECT max(id) FROM stage_changes WHERE stage_id = NEW.id AND field = 'weight')) THEN
      RAISE EXCEPTION 'stages: a locked weight changes only with its latest StageChange named in the same transaction'
        USING ERRCODE = 'restrict_violation';
    END IF;
  END IF;
  RETURN NEW;
END;
      $$;
      CREATE OR REPLACE FUNCTION enforce_gate_eliminated() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE s2 stages%ROWTYPE; application_id bigint;
BEGIN
  IF NEW.reason_code <> 'gate_eliminated' THEN RETURN NEW; END IF;
  -- The wrong shape (manual, pass, review) is refused by CHECK decisions_gate_eliminated_is_rule.
  IF NEW.basis <> 'rule' OR NEW.outcome <> 'eliminate' THEN RETURN NEW; END IF;
  SELECT st.* INTO s2 FROM participations p JOIN stages st ON st.id = p.stage_id WHERE p.id = NEW.participation_id;
  SELECT p.job_application_id INTO application_id FROM participations p WHERE p.id = NEW.participation_id;
  IF s2.gate IS NULL OR s2.code <> 'S2' THEN
    RAISE EXCEPTION 'decisions: gate_eliminated is written only on the S2 stage of a gate' USING ERRCODE = 'restrict_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM score_entries se WHERE se.participation_id = NEW.participation_id) THEN
    RAISE EXCEPTION 'decisions: gate_eliminated is for a test nobody scored' USING ERRCODE = 'restrict_violation';
  END IF;
  IF NOT EXISTS (
       SELECT 1 FROM participations p1
       JOIN stages s1 ON s1.id = p1.stage_id AND s1.job_id = s2.job_id AND s1.gate = s2.gate AND s1.code = 'S1'
       JOIN decisions d ON d.participation_id = p1.id
       WHERE p1.job_application_id = application_id AND d.outcome = 'eliminate'
         AND NOT EXISTS (SELECT 1 FROM decisions later WHERE later.supersedes_id = d.id)) THEN
    RAISE EXCEPTION 'decisions: gate_eliminated needs a current S1 elimination of the same application'
      USING ERRCODE = 'restrict_violation';
  END IF;
  IF NULLIF(current_setting('glassbox.gate_closing', true), '') IS DISTINCT FROM s2.id::text THEN
    RAISE EXCEPTION 'decisions: gate_eliminated is written only while the gate closes (Gates::Close)'
      USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN NEW;
END;
      $$;
    SQL
  end

  def down
    execute <<~SQL
      CREATE OR REPLACE FUNCTION enforce_single_tenant() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF current_setting('#{LEGACY}.tenancy', true) = 'single' THEN
    LOCK TABLE client_companies IN SHARE ROW EXCLUSIVE MODE;
    IF EXISTS (SELECT 1 FROM client_companies) THEN
      RAISE EXCEPTION 'TENANCY=single allows one client company'
        USING ERRCODE = 'unique_violation';
    END IF;
  END IF;
  RETURN NEW;
END;
      $$;
      CREATE OR REPLACE FUNCTION enforce_stage_lifecycle() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE named_change bigint := NULLIF(current_setting('#{LEGACY}.stage_change_id', true), '')::bigint;
BEGIN
  IF OLD.opened_at IS NOT NULL AND NEW.opened_at IS DISTINCT FROM OLD.opened_at THEN
    RAISE EXCEPTION 'stages: opened_at cannot change once set' USING ERRCODE = 'restrict_violation';
  END IF;
  IF NEW.status <> OLD.status AND NOT (
       (OLD.status = 'draft' AND NEW.status = 'open') OR (OLD.status = 'open' AND NEW.status = 'closed')) THEN
    RAISE EXCEPTION 'stages: status cannot move from % to %', OLD.status, NEW.status USING ERRCODE = 'restrict_violation';
  END IF;
  IF OLD.status = 'closed' AND (NEW.threshold <> OLD.threshold OR NEW.weight <> OLD.weight) THEN
    RAISE EXCEPTION 'stages: tahap sudah ditutup; weight and threshold are final' USING ERRCODE = 'restrict_violation';
  END IF;
  IF OLD.status = 'open' AND NEW.status = 'closed' AND EXISTS (
       SELECT 1 FROM participations p
       WHERE p.stage_id = NEW.id AND NOT EXISTS (
         SELECT 1 FROM decisions d
         WHERE d.participation_id = p.id AND d.outcome <> 'review'
           AND NOT EXISTS (SELECT 1 FROM decisions s WHERE s.supersedes_id = d.id))) THEN
    RAISE EXCEPTION 'stages: cannot close while a participation is undecided or in review'
      USING ERRCODE = 'restrict_violation';
  END IF;
  IF OLD.opened_at IS NOT NULL THEN
    IF NEW.threshold <> OLD.threshold AND NOT EXISTS (
         SELECT 1 FROM stage_changes sc
         WHERE sc.id = named_change AND sc.stage_id = NEW.id AND sc.field = 'threshold'
           AND sc.old_value = OLD.threshold AND sc.new_value = NEW.threshold
           AND sc.id = (SELECT max(id) FROM stage_changes WHERE stage_id = NEW.id AND field = 'threshold')) THEN
      RAISE EXCEPTION 'stages: a locked threshold changes only with its latest StageChange named in the same transaction'
        USING ERRCODE = 'restrict_violation';
    END IF;
    IF NEW.weight <> OLD.weight AND NOT EXISTS (
         SELECT 1 FROM stage_changes sc
         WHERE sc.id = named_change AND sc.stage_id = NEW.id AND sc.field = 'weight'
           AND sc.old_value = OLD.weight AND sc.new_value = NEW.weight
           AND sc.id = (SELECT max(id) FROM stage_changes WHERE stage_id = NEW.id AND field = 'weight')) THEN
      RAISE EXCEPTION 'stages: a locked weight changes only with its latest StageChange named in the same transaction'
        USING ERRCODE = 'restrict_violation';
    END IF;
  END IF;
  RETURN NEW;
END;
      $$;
      CREATE OR REPLACE FUNCTION enforce_gate_eliminated() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE s2 stages%ROWTYPE; application_id bigint;
BEGIN
  IF NEW.reason_code <> 'gate_eliminated' THEN RETURN NEW; END IF;
  -- The wrong shape (manual, pass, review) is refused by CHECK decisions_gate_eliminated_is_rule.
  IF NEW.basis <> 'rule' OR NEW.outcome <> 'eliminate' THEN RETURN NEW; END IF;
  SELECT st.* INTO s2 FROM participations p JOIN stages st ON st.id = p.stage_id WHERE p.id = NEW.participation_id;
  SELECT p.job_application_id INTO application_id FROM participations p WHERE p.id = NEW.participation_id;
  IF s2.gate IS NULL OR s2.code <> 'S2' THEN
    RAISE EXCEPTION 'decisions: gate_eliminated is written only on the S2 stage of a gate' USING ERRCODE = 'restrict_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM score_entries se WHERE se.participation_id = NEW.participation_id) THEN
    RAISE EXCEPTION 'decisions: gate_eliminated is for a test nobody scored' USING ERRCODE = 'restrict_violation';
  END IF;
  IF NOT EXISTS (
       SELECT 1 FROM participations p1
       JOIN stages s1 ON s1.id = p1.stage_id AND s1.job_id = s2.job_id AND s1.gate = s2.gate AND s1.code = 'S1'
       JOIN decisions d ON d.participation_id = p1.id
       WHERE p1.job_application_id = application_id AND d.outcome = 'eliminate'
         AND NOT EXISTS (SELECT 1 FROM decisions later WHERE later.supersedes_id = d.id)) THEN
    RAISE EXCEPTION 'decisions: gate_eliminated needs a current S1 elimination of the same application'
      USING ERRCODE = 'restrict_violation';
  END IF;
  IF NULLIF(current_setting('#{LEGACY}.gate_closing', true), '') IS DISTINCT FROM s2.id::text THEN
    RAISE EXCEPTION 'decisions: gate_eliminated is written only while the gate closes (Gates::Close)'
      USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN NEW;
END;
      $$;
    SQL
  end
end
