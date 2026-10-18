require "test_helper"

# The UI wording standard: words that never appear in what a user reads (D42–D45 and the
# house rules). Scans views, Ruby files under app/ and lib/, the mailers and the locales; comment
# lines are skipped (code comments are English and may quote the old word). No exceptions: the
# former exception "Seleksi berkas" became "Seleksi CV" (D46, GlassBox Team 07:54).
class UiWordingTest < ActiveSupport::TestCase
  BANNED = {
    /\btautan\b/i => "Link (D42)",
    /\bcorong seleksi\b/i => "Review Seleksi (D43)",
    /\btatap muka\b/i => "Offline/Kehadiran di lokasi (D45)",
    /\bberkas\b/i => "file (D44)",
    /\b(unggah\w*|diunggah|mengunggah)\b/i => "upload (D44)",
    /\b(terapkan|diterapkan)\b/i => "Filter / Simpan / Apply (global rule)"
  }.freeze
  EXCEPTIONS = [].freeze

  test "no banned word appears in UI text" do
    files = Dir[Rails.root.join("{app,lib,config/locales}/**/*.{rb,erb,yml}")]
    assert_operator files.size, :>, 80, "the scan read too few files; the glob is wrong"
    hits = files.flat_map do |file|
      File.readlines(file).each_with_index.filter_map do |line, index|
        stripped = line.strip
        next if stripped.start_with?("#", "<%#")
        text = EXCEPTIONS.reduce(line) { |acc, ex| acc.gsub(ex, "") }
        BANNED.filter_map { |pattern, use| "#{file.sub("#{Rails.root}/", '')}:#{index + 1} use #{use}" if text.match?(pattern) }
      end.flatten
    end
    assert_empty hits, "banned UI words:\n#{hits.join("\n")}"
  end
end
