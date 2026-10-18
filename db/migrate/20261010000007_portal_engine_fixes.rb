# Portal test-engine run, 2026-10-10.
class PortalEngineFixes < ActiveRecord::Migration[8.1]
  def change
    # F12: who marked a failed email as handled.
    add_column :mail_deliveries, :handled_by_id, :bigint

    # F7: "consent_retention_days > 0" evaluates to NULL for NULL, and a NULL check passes in SQL,
    # so an application with a candidate but no retention period was accepted. IS NOT NULL closes it.
    remove_check_constraint :job_applications, name: "job_applications_consent_recorded"
    add_check_constraint :job_applications,
      "candidate_id IS NULL OR (consent_at IS NOT NULL AND consent_template_id IS NOT NULL " \
      "AND consent_retention_days IS NOT NULL AND consent_retention_days > 0)",
      name: "job_applications_consent_recorded"
  end
end
