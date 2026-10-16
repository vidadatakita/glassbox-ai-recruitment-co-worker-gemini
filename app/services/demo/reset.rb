module Demo
  # A5: puts the demo workspace back to its seeded state. Runs nightly (DemoResetJob, config/recurring.yml)
  # and by hand (`bin/rails glassbox:demo:reset`).
  #
  # Why drop the schema instead of deleting rows: a third of the tables are append-only by database
  # trigger (DELETE and TRUNCATE are refused on purpose, blueprint §2.1), so the only honest reset is
  # the one a fresh install gets: drop the schema, load db/structure.sql, run db/seeds.rb. Everything
  # a visitor did during the day, and every file they uploaded, is gone afterwards.
  #
  # Guard: refuses to run unless DEMO_MODE=1. On a client install this class must never run; the
  # guard is the first line, before any connection is touched. The result is one structured log line
  # (duration, row counts after) so the night's reset can be checked from the logs the next morning.
  class Reset
    Result = Struct.new(:success?, :payload, :error, keyword_init: true)

    def self.call(now: Time.current) = new(now:).call

    def initialize(now:)
      @now = now
    end

    def call
      return Result.new(success?: false, error: "DEMO_MODE is not 1; refusing to reset a non-demo database") unless Glassbox::Settings.demo_mode?

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      purge_files!
      reload_schema!
      Rails.application.load_seed
      counts = { users: User.count, jobs: Job.count, applications: JobApplication.count }
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      Rails.logger.info("[demo_reset] outcome=ok duration_ms=#{duration_ms} #{counts.map { |k, v| "#{k}=#{v}" }.join(' ')} at=#{@now.iso8601}")
      Result.new(success?: true, payload: counts.merge(duration_ms:))
    rescue StandardError => e
      Rails.logger.error("[demo_reset] outcome=error error_class=#{e.class} error_message=#{e.message.truncate(200)}")
      raise
    end

    private

    # Uploaded files (CVs, test answers, offer PDFs) live outside the database; dropping the schema
    # would orphan them in the bucket. Purge first, while the blob rows still exist.
    def purge_files!
      ActiveStorage::Blob.find_each(&:purge)
    end

    def reload_schema!
      connection = ActiveRecord::Base.connection
      connection.execute("DROP SCHEMA public CASCADE; CREATE SCHEMA public;")
      ActiveRecord::Tasks::DatabaseTasks.load_schema(ActiveRecord::Base.connection_db_config, :sql)
      connection.schema_cache.clear!
      ActiveRecord::Base.descendants.each(&:reset_column_information)
    end
  end
end
