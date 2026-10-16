module GoogleIntegration
  # `bin/rails glassbox:google:migrate_storage` (D52 (3)): copies files stored on local disk into the
  # Cloud Storage bucket, one blob at a time.
  #
  # Order per blob, and why:
  # 1. read the local file (Active Storage verifies it against blob.checksum while reading);
  # 2. upload under the SAME key with the same checksum, content type and
  #    "Content-Disposition: attachment" (Google refuses the upload if the MD5 differs);
  # 3. read the stored object's MD5 back from the bucket and compare it with blob.checksum;
  # 4. only then point the blob at "google" (service_name).
  # The local file is NEVER deleted: it is the rollback. Deleting it is a separate, later decision
  # (runbook §6). A blob that fails stays on "local" and keeps working; the task reports it and
  # exits non-zero. DRY_RUN (the default) only lists what would be copied.
  class StorageMigration
    Line = Data.define(:blob_id, :outcome, :detail)

    def initialize(dry_run:, source: nil, target: nil, target_name: "google", logger: nil)
      @dry_run = dry_run
      @source = source || ActiveStorage::Blob.services.fetch(:local)
      @target = target || ActiveStorage::Blob.services.fetch(:google)
      @target_name = target_name
      @logger = logger
    end

    def run
      ActiveStorage::Blob.where(service_name: "local").order(:id).find_each.map { |blob| migrate(blob) }
    end

    private

    def migrate(blob)
      return say(Line.new(blob.id, :missing, "local file missing (#{blob.key})")) unless @source.exist?(blob.key)
      return say(Line.new(blob.id, :would_copy, "#{blob.byte_size} bytes, #{blob.content_type}")) if @dry_run

      @source.open(blob.key, checksum: blob.checksum) do |file|
        @target.upload(blob.key, file, checksum: blob.checksum, content_type: blob.content_type,
                                       disposition: :attachment, filename: blob.filename)
      end
      remote = remote_checksum(blob.key)
      unless remote == blob.checksum
        return say(Line.new(blob.id, :failed, "checksum differs after upload (local #{blob.checksum}, bucket #{remote.inspect}); blob stays on local disk"))
      end

      blob.update_columns(service_name: @target_name)
      say(Line.new(blob.id, :copied, "#{blob.byte_size} bytes, checksum matches"))
    rescue ActiveStorage::IntegrityError, ActiveStorage::FileNotFoundError, Glassbox::GoogleKey::Invalid, *Calendar::FAILURES.filter_map(&:safe_constantize),
           *[ "Google::Cloud::Error" ].filter_map(&:safe_constantize) => e
      say(Line.new(blob.id, :failed, "#{e.class.name}: #{Glassbox::GoogleKey.redact(e.message).truncate(200)}; blob stays on local disk"))
    end

    # The MD5 the TARGET holds for the key, base64 like blob.checksum. For Cloud Storage it is the
    # object's md5 metadata; for any other service (tests use Disk) the stored bytes are re-read.
    def remote_checksum(key)
      if @target.class.name == "ActiveStorage::Service::GCSService"
        @target.send(:bucket).file(key)&.md5
      else
        OpenSSL::Digest::MD5.base64digest(@target.download(key))
      end
    end

    def say(line)
      @logger&.call(line)
      line
    end
  end
end
