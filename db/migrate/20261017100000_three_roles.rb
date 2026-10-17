# frozen_string_literal: true

# Three roles (GlassBox Team, 17 Oct 2026): superadmin, hr_admin, hr_manager replace owner, hr_pic,
# consultant, reviewer and admin.
#   hr_admin   = hr_pic + consultant: brief, ad, portal, start screening, calibration, test case,
#                the step-9 decision, interview links, objections, offer upload
#   hr_manager = reviewer + owner: Send to Gemini, review of flagged results, technical-test scoring,
#                salary agreement
#   superadmin = admin, and passes every role check (team decision)
#
# Every database function that names a role is rewritten from its LIVE definition
# (pg_get_functiondef), so no function body is retyped here: each `<expr> IS DISTINCT FROM 'old'`
# becomes `COALESCE(<expr>, '') NOT IN ('new', 'superadmin')`, and each `role = 'old'` becomes
# `role IN ('new', 'superadmin')`. NULL-safe on purpose: a bare `x NOT IN (...)` is NULL for a missing
# user and would let the row through. The guards that compare a PERSON (the reviewer is never the
# vacancy's consultant) compare ids and are untouched.
class ThreeRoles < ActiveRecord::Migration[8.1]
  MAP = { "hr_pic" => "hr_admin", "consultant" => "hr_admin", "reviewer" => "hr_manager",
          "owner" => "hr_manager", "admin" => "superadmin" }.freeze
  OLD = MAP.keys.join("|")

  def up
    execute "ALTER TABLE users DROP CONSTRAINT users_role"
    execute "ALTER TABLE users DROP CONSTRAINT users_client_roles_have_company"
    MAP.each { |old, new| execute "UPDATE users SET role = #{connection.quote(new)} WHERE role = #{connection.quote(old)}" }
    # TENANCY=single: an hr_admin or hr_manager without a company (a former consultant or reviewer)
    # joins the install's one company, so the company rule below holds. Nothing to do on an empty install.
    execute <<~SQL
      UPDATE users SET client_company_id = (SELECT id FROM client_companies ORDER BY id LIMIT 1)
      WHERE role IN ('hr_admin', 'hr_manager') AND client_company_id IS NULL
        AND (SELECT count(*) FROM client_companies) = 1
    SQL
    execute "ALTER TABLE users ALTER COLUMN role SET DEFAULT 'hr_admin'"
    execute "ALTER TABLE users ADD CONSTRAINT users_role CHECK (role IN ('superadmin', 'hr_admin', 'hr_manager'))"
    execute "ALTER TABLE users ADD CONSTRAINT users_client_roles_have_company " \
            "CHECK (role NOT IN ('hr_admin', 'hr_manager') OR client_company_id IS NOT NULL)"
    rewrite_role_functions
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "five roles were merged into three; which hr_admin was a consultant is not recorded"
  end

  private

  def rewrite_role_functions
    defs = select_values(<<~SQL)
      SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.prokind = 'f'
        AND pg_get_functiondef(p.oid) ~ 'role' AND pg_get_functiondef(p.oid) ~ '''(#{OLD})'''
    SQL
    raise "expected the role-guard functions, found none" if defs.empty?

    defs.each do |definition|
      fixed = definition
              .gsub(/(\(SELECT role FROM users WHERE id = NEW\.\w+\)|\b\w+_role\b) IS DISTINCT FROM '(#{OLD})'/) { "COALESCE(#{$1}, '') NOT IN ('#{MAP[$2]}', 'superadmin')" }
              .gsub(/role = '(#{OLD})'/) { "role IN ('#{MAP[$1]}', 'superadmin')" }
      left = fixed.scan(/'(?:#{OLD})'/)
      raise "a role literal is left in a guard function: #{left.uniq.join(', ')}\n#{fixed[0, 200]}" if left.any?

      execute(fixed)
    end
  end
end
