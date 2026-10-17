require "test_helper"

# Every piece of demo data is English (GlassBox Team, 17 Oct 2026), the legacy seeds behind
# LEGACY_DEMO_SEEDS=1 included. This scans the STRING LITERALS of db/seeds.rb and db/seeds/*.rb
# (comment lines skipped) for Indonesian function words and recruitment nouns. The English demo-path
# gate (english_demo_path_test.rb) scans app/ and lib/ only, so without this file a seed could bring
# Bahasa back unseen.
#
# Kept on purpose, so allowed as exact strings: stored codes the app matches on (requirement tiers,
# decision codes, label proposals), and Impact::DEMO_MODEL, which app/services/impact.rb matches
# byte for byte. Invented names such as "PT Contoh Maju Bersama" and the contoh.example domain are
# names, and "contoh" is not in the word list.
class EnglishSeedDataTest < ActiveSupport::TestCase
  FILES = ([Rails.root.join("db/seeds.rb").to_s] + Dir[Rails.root.join("db/seeds/*.rb")]).sort.freeze

  WORDS = %w[
    dan yang untuk dengan tidak sudah belum atau dari pada kami anda saya harus bersedia pengalaman minimal
    tahun bulan hari lowongan kandidat pelamar iklan tentang posisi pekerjaan gaji lamaran wawancara catatan
    alasan staf gudang penilaian laporan pengaturan uji surat tanggal kantor cabang menyusun mencatat
    keuangan barang masuk keluar kesalahan jawaban petunjuk gerbang ditutup terbuka sebagai istri suami
    pemeriksaan sebelum dampak
  ].freeze
  WORD_RE = /\b(?:#{WORDS.join('|')})\b/i

  ALLOWED = %w[
    wajib sebaiknya nilai_tambah lanjut tidak_lanjut ikut_ai direkomendasikan pertimbangkan
    pertimbangkan_terbatas tidak_prioritas tidak_relevan kontrak_pkwt tetap_pkwtt diutamakan tidak_perlu
  ].push(Impact::DEMO_MODEL).to_set.freeze

  def self.hits_in(source, name = "source")
    source.each_line.with_index(1).flat_map do |line, number|
      next [] if line.strip.start_with?("#")

      line.scan(/"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'/).filter_map do |double, single|
        text = double || single
        next if ALLOWED.include?(text)

        "#{name}:#{number}: #{text[0, 80]}" if text.match?(WORD_RE)
      end
    end
  end

  test "the scan reads every seed file" do
    assert_operator FILES.size, :>=, 9, FILES.inspect
    assert(FILES.any? { |f| f.end_with?("demo_glassbox.rb") })
  end

  test "no Indonesian sentence is left in the demo data" do
    hits = FILES.flat_map { |f| self.class.hits_in(File.read(f), f.delete_prefix("#{Rails.root}/")) }
    assert_empty hits, "Indonesian demo data (translate it, or allow a stored code above):\n#{hits.join("\n")}"
  end

  test "control: the scan catches a planted Indonesian string and passes a code and a name" do
    planted = <<~'RUBY'
      title: "Staf Admin Gudang"
      tier: "wajib"
      company: "PT Contoh Maju Bersama"
    RUBY
    hits = self.class.hits_in(planted)
    assert_equal 1, hits.size, hits.inspect
    assert_match(/Staf Admin Gudang/, hits.first)
  end
end
