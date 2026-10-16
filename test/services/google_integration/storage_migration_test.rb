require "test_helper"
require "active_storage/service/disk_service"

# D52 (3): moving existing files from local disk to the bucket. Dry run changes nothing; a real
# run copies, verifies the checksum, re-points the blob and NEVER deletes the local copy; a copy
# whose checksum does not match leaves the blob on local disk. Two Disk services stand in for
# local and Cloud Storage, so no Google call is made.
class GoogleIntegration::StorageMigrationTest < ActiveSupport::TestCase
  setup do
    @root = Dir.mktmpdir("glassbox-migrate")
    @source = ActiveStorage::Service::DiskService.new(root: File.join(@root, "local"))
    @target = ActiveStorage::Service::DiskService.new(root: File.join(@root, "bucket"))
    @bytes = "%PDF-1.4 CV uji\n%%EOF\n"
    @blob = ActiveStorage::Blob.create!(key: "ujikey#{SecureRandom.hex(6)}", filename: "cv.pdf", content_type: "application/pdf",
                                        byte_size: @bytes.bytesize, checksum: OpenSSL::Digest::MD5.base64digest(@bytes), service_name: "local")
    @source.upload(@blob.key, StringIO.new(@bytes), checksum: @blob.checksum)
  end

  teardown { FileUtils.rm_rf(@root) }

  def migration(dry_run:, target: @target) = GoogleIntegration::StorageMigration.new(dry_run:, source: @source, target:, target_name: "google")

  test "dry run lists the blob and changes nothing" do
    lines = migration(dry_run: true).run
    assert_equal [ :would_copy ], lines.select { |l| l.blob_id == @blob.id }.map(&:outcome)
    refute @target.exist?(@blob.key)
    assert_equal "local", @blob.reload.service_name
  end

  test "a real run copies, verifies, re-points the blob and keeps the local file" do
    lines = migration(dry_run: false).run
    assert_equal [ :copied ], lines.select { |l| l.blob_id == @blob.id }.map(&:outcome)
    assert_equal @bytes, @target.download(@blob.key)
    assert_equal "google", @blob.reload.service_name
    assert @source.exist?(@blob.key), "the local copy is the rollback and is never deleted"
  end

  test "a checksum that does not match after upload leaves the blob on local disk" do
    corrupting = @target.dup
    corrupting.define_singleton_method(:download) { |_key| "rusak" }
    lines = migration(dry_run: false, target: corrupting).run
    line = lines.find { |l| l.blob_id == @blob.id }
    assert_equal :failed, line.outcome
    assert_match "checksum differs", line.detail
    assert_equal "local", @blob.reload.service_name
  end

  test "a local file that is missing is reported, not skipped silently" do
    @source.delete(@blob.key)
    line = migration(dry_run: false).run.find { |l| l.blob_id == @blob.id }
    assert_equal :missing, line.outcome
    assert_equal "local", @blob.reload.service_name
  end
end
