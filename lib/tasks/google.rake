# Operator tasks for the Google integrations (D52).
# None of them prints a client secret, an app password or the service-account key.
namespace :glassbox do
  namespace :google do
    desc "Check each configured Google integration with one harmless call (or report 'not configured')"
    task check: :environment do
      results = GoogleIntegration::Check.run
      results.each do |r|
        label = { off: "NOT CONFIGURED", ok: "OK", failed: "FAILED" }.fetch(r.status)
        puts format("%-9s %-14s %s", r.integration, label, r.message)
      end
      # A failed check must fail the command too, so a deploy script cannot read it as green.
      abort "One or more Google integrations FAILED. See the lines above." if results.any? { |r| r.status == :failed }
    end

    desc "Copy files from local disk to Google Cloud Storage. Dry run unless DRY_RUN=0. Never deletes the local copy."
    task migrate_storage: :environment do
      dry_run = ENV.fetch("DRY_RUN", "1") != "0"
      abort "Cloud Storage is not configured (GOOGLE_STORAGE_BUCKET + GOOGLE_SERVICE_ACCOUNT_JSON)." unless GoogleIntegration::Config.storage_configured?

      puts dry_run ? "DRY RUN: nothing is copied. Run with DRY_RUN=0 to copy." : "Copying to bucket #{GoogleIntegration::Config.storage_bucket}; local files are kept."
      lines = GoogleIntegration::StorageMigration.new(dry_run:, logger: ->(l) { puts format("blob %-8s %-11s %s", l.blob_id, l.outcome, l.detail) }).run
      counts = lines.group_by(&:outcome).transform_values(&:size)
      puts "Summary: #{lines.size} blob(s) on local; #{counts.map { |k, v| "#{k} #{v}" }.join(', ').presence || 'nothing to do'}"
      abort "Some blobs were NOT migrated (failed or missing). They stay on local disk and keep working." if counts[:failed].to_i + counts[:missing].to_i > 0
    end
  end
end
