require "test_helper"

# A3 gate (16 Oct 2026): every screen on the Cup demo path reads in English. This scans the SOURCE
# of the demo-path views, mails, controllers, helpers, presenters and the models and services that
# produce screen text, for Indonesian function words and the recurring UI nouns, with word
# boundaries, skipping comment lines. It scans source rather than rendered pages on purpose:
# fixture CVs and seed data are legitimately Indonesian (they are the invented candidates) and would
# drown the signal, and a rendered page only covers the branches a test happens to render.
#
# Scope = every screen the app can render (the demo path of FLOW v2.1 and the staff screens A4 hides
# from the live URL), so a route un-hidden later cannot bring Bahasa back. A new view directory is
# added to SCOPE, or the gate is silently narrower than the claim it protects.
#
# Red by construction: written before the translation, with the hit count recorded in
# docs/BUILD-LOG.md, so a green here means the words were actually removed.
class EnglishDemoPathTest < ActiveSupport::TestCase
  SCOPE = %w[
    app/views/layouts app/views/sessions app/views/lamar app/views/candidate_shared app/views/candidate_status
    app/views/candidate_mailer app/views/candidate_tests app/views/interviewer_scores app/views/link_requests
    app/views/staff/shared app/views/staff/jobs app/views/staff/job_briefs app/views/staff/job_ads
    app/views/staff/ai_releases app/views/staff/screenings app/views/staff/screening_reports
    app/views/staff/applications app/views/staff/test_cases app/views/staff/test_scorings
    app/views/staff/work_queues app/views/staff/settings app/views/staff/impacts app/views/passwords
    app/views/passwords_mailer app/views/pwa app/views/demo_sessions
    app/controllers app/helpers app/presenters app/mailers app/jobs
    app/models app/services lib/glassbox lib/tasks
  ].freeze

  # Function words that occur in almost every Indonesian sentence, plus the UI nouns and verbs the
  # glossary translates. Word-bounded and case-insensitive. Deliberately NOT included: words that
  # are also English or are legitimate stored values (ai, data, status, form, email, admin, owner,
  # reviewer, lanjut / tidak_lanjut / wajib / sebaiknya as enum values are matched only as whole
  # words with spaces, so `"wajib"` in a tier comparison still hits and is allowed below).
  STOPWORDS = %w[
    yang untuk dengan tidak sudah belum akan atau silakan harus pelamar lowongan lamaran disimpan dicatat
    tahap kandidat periksa simpan kirim batal kembali tutup buka ubah hapus tambah lolos gagal menunggu
    selesai dibuka ditutup diterima ditolak persetujuan penawaran keberatan penilai penilaian jadwal
    syarat bobot ambang gaji jabatan golongan tes teknis seleksi gerbang rekomendasi saran catatan alasan
    coba lagi terlalu banyak percobaan masuk keluar kata sandi tanggal pukul hari jam menit
    terapkan diterapkan
  ].freeze
  STOPWORD_RE = /\b(?:#{STOPWORDS.map { |w| Regexp.escape(w) }.join('|')})\b/i

  # Enum values and identifiers that are Indonesian words but are NOT screen text. Matched as the
  # exact token so a sentence using the same word is still a hit.
  # Identifiers that are Indonesian words but never screen text, matched as exact tokens. golongan,
  # saran and periksa are column, param and method names everywhere (their labels are English);
  # commit values on the technical-test buttons are params nothing dispatches on (visible text is
  # English). /x ignores spaces, so a literal space is written as [ ].
  ALLOWED_TOKENS = /"(?:wajib|sebaiknya|nilai_tambah|lanjut|tidak_lanjut|ikut_ai|tidak|ya|S1|S2|lamar|penilaian|iklan|
                      tes-teknis|pemeriksaan-ai|direkomendasikan|pertimbangkan|pertimbangkan_terbatas|tidak_prioritas|
                      tidak_relevan|instruksi|wawancara|nilai|pilihan|penilai|kirim|hapus-bagian|tidak-dikirim|
                      selesai|brief\/selesai|portal\/open|gerbang-seleksi|penawaran)"|:(?:wajib|sebaiknya|nilai_tambah|lanjut|tidak_lanjut|lamaran)\b|
                      lamaran\[\w+\]|id="penawaran"|\bgolongan\b|\bsaran\b|\bperiksa\b|job_golongan|
                      value="(?:Mulai[ ]tes|Kirim[ ]jawaban|Kirim[ ]link)"|studi-kasus-tes-teknis|jawaban-tes-/x

  # Files whose remaining Indonesian words are stored data keys, not screen text: the staff data chat
  # writes its planner JSON (keys such as pelamar, lowongan, tahap; status values lolos / tidak_lolos)
  # into data_questions.data and replays it, so renaming them would break every stored conversation.
  # Their screen text was translated; the keys are excluded here on purpose, file by file.
  DATA_KEY_FILES = %w[app/services/data_chat.rb app/services/data_chat/tools.rb].freeze
  # Detector patterns and the invented sample CV: Indonesian by design (the redactor, the residual
  # check and the injection check look for Indonesian CV labels; the sample CV is Indonesian data).
  DETECTOR_FILES = %w[app/models/screening/redactor.rb app/models/screening/residual_check.rb
                      app/models/screening/injection_check.rb app/models/screening/cv_sections.rb
                      app/models/screening/sample.rb].freeze

  def scope_files
    SCOPE.flat_map { |dir| Dir[Rails.root.join(dir, "**", "*.{rb,erb,rake}")] }.uniq.sort
         .reject { |f| (DATA_KEY_FILES + DETECTOR_FILES).any? { |x| f.end_with?(x) } }
  end

  def hits
    scope_files.flat_map do |path|
      File.readlines(path, chomp: true).each_with_index.filter_map do |line, i|
        stripped = line.strip
        next if stripped.start_with?("#", "<%#", "//")
        # A detector pattern (RULES = /…/, UNITS = /…/) lists the Indonesian words it looks for; that
        # is behaviour, not screen text, so a constant assigned a regex literal is skipped whole.
        next if stripped.match?(/\A[A-Z_]+\s*=\s*(?:Regexp\.|\/|%r)/)
        # Regex literals inside a line (the ad-check rule table lists the Indonesian phrases it flags)
        # are behaviour, not screen text, and are stripped before the scan.
        text = line.gsub(/<%#.*?%>/m, "").gsub(%r{/(?:\\/|[^/\n])+/[imx]*}, "").gsub(ALLOWED_TOKENS, "")
        # Drop the Ruby comment tail of a code line; keep everything a user could read.
        text = text.sub(/\s#\s.*\z/, "") if path.end_with?(".rb")
        words = text.scan(STOPWORD_RE).map(&:downcase).uniq
        "#{path.sub("#{Rails.root}/", '')}:#{i + 1} #{words.join(',')}" if words.any?
      end
    end
  end

  test "the scan reads the demo path" do
    files = scope_files
    assert_operator files.size, :>, 150, "the scan read too few files; a SCOPE directory is wrong"
    assert files.any? { |f| f.end_with?("app/views/lamar/form.html.erb") }
    assert files.any? { |f| f.end_with?("app/views/staff/applications/_progression.html.erb") }
  end

  test "no Indonesian word is left in the demo-path source" do
    found = hits
    shown = ENV["GATE_ALL"] ? found : found.first(80)
    assert_empty found, "#{found.size} lines still carry Indonesian screen text:\n#{shown.join("\n")}"
  end

  test "the button verb Terapkan appears nowhere" do
    offenders = Dir[Rails.root.join("app/**/*.{rb,erb,js}")].select { |f| File.read(f).match?(/terapkan/i) }
    assert_empty offenders.map { |f| f.sub("#{Rails.root}/", "") }
  end

  test "the AI output is labelled AI advice and the three choices use the fixed wording" do
    progression = File.read(Rails.root.join("app/views/staff/applications/_progression.html.erb"))
    assert_includes progression, "AI advice"
    refute_match(/\bAI recommendation\b/, progression)
    %w[Continue Do\ not\ continue Follow\ AI\ advice].each { |w| assert_includes progression, w }
  end
end
