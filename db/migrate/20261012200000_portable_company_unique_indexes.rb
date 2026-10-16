# Rebuilds the two "one row per company, and one platform-wide row" unique indexes in a form that
# works on PostgreSQL 12 (development, D31) as well as 15+. Migration 20261011030815 first created
# them with NULLS NOT DISTINCT (PostgreSQL 15+ only); databases that ran that version keep a working
# index, but structure.sql dumped from them cannot be loaded on PostgreSQL 12. Dropping and
# recreating with COALESCE(client_company_id, 0) gives the same rule everywhere (company ids start
# at 1, so 0 stands for "no company"). Safe to run on a database that already has the new form.
class PortableCompanyUniqueIndexes < ActiveRecord::Migration[8.1]
  def up
    execute "DROP INDEX IF EXISTS index_system_settings_on_company_and_key"
    execute "CREATE UNIQUE INDEX index_system_settings_on_company_and_key ON system_settings (COALESCE(client_company_id, 0), key)"
    execute "DROP INDEX IF EXISTS index_consent_templates_on_company_and_version"
    execute "CREATE UNIQUE INDEX index_consent_templates_on_company_and_version ON consent_templates (COALESCE(client_company_id, 0), version)"
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
