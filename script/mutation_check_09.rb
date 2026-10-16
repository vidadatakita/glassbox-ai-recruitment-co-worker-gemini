# frozen_string_literal: true

# Feature 09 (D51 release gate) red runs: each mutation breaks one guard in the real code; the named
# tests MUST fail against it (skill load-bearing-tests: a green never made red is decoration).
#
# Unlike script/mutation_check_06.rb this runs in a COPY of the project (rsync to a temp dir), so
# the shared development server never serves mutated code, even for a second.
#
#   TEST_DATABASE=glassbox_test_release ruby script/mutation_check_09.rb [ID prefix ...]
require "tmpdir"
require "fileutils"

MUTATIONS = [
  { id: "G1", rule: "D51 B: nothing is sent before a release (gate returns a pending version)",
    subs: [["app/services/screening/release_gate.rb", "if latest&.released? && !latest.consumed?", "if latest && !latest.consumed?"],
           ["app/services/screening/release_gate.rb", "      prepare(latest)\n      nil\n    end", "      prepare(latest)\n      AiRelease.latest_for(@participation, KIND)\n    end"]],
    tests: %w[test/services/ai_releases/release_gate_test.rb] },
  { id: "G2", rule: "D51 B: the client re-checks the digest immediately before the call",
    subs: [["app/services/screening/ai_client.rb", 'if Digest::SHA256.hexdigest(payload.to_s.encode("UTF-8")) != sha256.to_s', "if false"]],
    tests: %w[test/services/ai_releases/release_gate_test.rb] },
  { id: "G3", rule: "D51 B: the gate refuses a released text whose digest no longer matches",
    subs: [["app/services/screening/release_gate.rb", "intact = release.digest_intact? && release.action.payload_sha256 == release.payload_sha256", "intact = true"]],
    tests: %w[test/services/ai_releases/release_gate_test.rb] },
  { id: "G4", rule: "D51 B: the sent text is the released text, byte for byte",
    subs: [["app/services/screening/ai_client.rb", "sending(release.payload_text) { call_api(release.payload_text, system: SYSTEM_PROMPT, schema: SCHEMA) }", "sending(release.payload_text.sub(\"\\n\\n<cv>\", \"\\n<cv>\")) { |t| call_api(t, system: SYSTEM_PROMPT, schema: SCHEMA) }"]],
    tests: %w[test/services/ai_releases/release_gate_test.rb] },
  { id: "G5", rule: "D51 B: release needs the reviewer's tick",
    subs: [["app/services/ai_releases/release.rb", 'raise Refused, "Centang pernyataan bahwa Anda sudah memeriksa teks ini." unless @confirmed', ""]],
    tests: %w[test/services/ai_releases/release_gate_test.rb test/integration/ai_release_screens_test.rb] },
  { id: "G6", rule: "D51 B: release needs the digest of the version the reviewer saw",
    subs: [["app/services/ai_releases/release.rb", "unless @seen == @release.payload_sha256", "if false"]],
    tests: %w[test/services/ai_releases/release_gate_test.rb] },
  { id: "G7", rule: "C/ADR 0004: a version with residual findings is never released (service)",
    subs: [["app/services/ai_releases/release.rb", "if @release.residual?", "if false"]],
    tests: %w[test/services/ai_releases/release_gate_test.rb test/services/screening/failure_policy_test.rb test/integration/ai_release_screens_test.rb] },
  { id: "G8", rule: "Reviewer only, never the job's consultant (service)",
    subs: [["app/services/ai_releases.rb", 'raise Refused, "Hanya reviewer yang dapat memeriksa teks sebelum dikirim ke AI." unless user&.role == "reviewer"', ""],
           ["app/services/ai_releases.rb", 'raise Refused, "Reviewer tidak boleh konsultan lowongan ini." if consultant_id.present? && consultant_id == user.id', ""]],
    tests: %w[test/services/ai_releases/release_gate_test.rb] },
  { id: "G9", rule: "A cut only touches CV lines",
    subs: [["app/services/ai_releases/cut.rb", 'raise Refused, "Hanya baris CV yang dapat dihapus." unless @numbers.all? { |n| @release.cv_range.cover?(n) }', ""]],
    tests: %w[test/services/ai_releases/release_gate_test.rb] },
  { id: "G10", rule: "A cut replaces, never adds",
    subs: [["app/services/ai_releases/cut.rb", "@numbers.each { |n| lines[n] = Screening::Redactor::MARK }", '@numbers.each { |n| lines[n] = "#{Screening::Redactor::MARK} #{lines[n]}" }']],
    tests: %w[test/services/ai_releases/release_gate_test.rb] },
  { id: "G11", rule: "Tidak dikirim needs a note",
    subs: [["app/services/ai_releases/decline.rb", 'raise Refused, "Tulis alasan mengapa teks ini tidak dikirim." if @note.empty?', ""]],
    tests: %w[test/services/ai_releases/release_gate_test.rb test/integration/ai_release_screens_test.rb] },
  { id: "G12", rule: "A gate closed while waiting (consent withdrawn) refuses the release",
    subs: [["app/services/screening/release_handler.rb", "if (reason = Enqueue.blocked_reason(participation))", "if (reason = nil)"]],
    tests: %w[test/services/ai_releases/release_gate_test.rb] },
  { id: "G13", rule: "An outdated release (rubric changed) is never sent",
    subs: [["app/services/screening/release_gate.rb", "def fresh?(release) = release.rubric_digest == @rubric.digest && release.source_sha256 == @source_sha", "def fresh?(release) = true"]],
    tests: %w[test/services/ai_releases/release_gate_test.rb] },
  { id: "G14", rule: "No key: release refused, text waits",
    subs: [["app/services/screening/release_handler.rb", 'raise AiReleases::Refused, ScreeningBoard::OFF_MESSAGE + " Teks tetap menunggu di sini." unless Config.enabled?', ""]],
    tests: %w[test/services/screening/gates_test.rb] },
  { id: "A1", rule: "D51 A: only evidence sections are kept",
    subs: [["app/models/screening/evidence_sections.rb", "when :other then keeping = false", "when :other then keeping = keeping"]],
    tests: %w[test/models/screening/evidence_sections_test.rb] },
  { id: "A2", rule: "D51 A: no evidence section -> not sent",
    subs: [["app/models/screening/evidence_sections.rb", "return nil unless found", "return text.to_s.strip unless found"]],
    tests: %w[test/models/screening/evidence_sections_test.rb test/services/screening/failure_policy_test.rb] },
  { id: "A3", rule: "D51 A applied before redaction in the pipeline",
    subs: [["app/services/screening/release_gate.rb", "evidence = EvidenceSections.keep(@text)", "evidence = @text"]],
    tests: %w[test/services/screening/failure_policy_test.rb test/services/screening/outgoing_request_test.rb] },
  { id: "S1", rule: "The screen's text block is the payload byte for byte",
    subs: [["app/helpers/ai_releases_helper.rb", "out << h(line[pos..]) if pos < line.length", "out << h(line[pos..-2]) if pos < line.length"]],
    tests: %w[test/integration/ai_release_screens_test.rb] },
  { id: "S2", rule: "HR PIC / owner / consultant never open the screen",
    subs: [["app/controllers/staff/ai_releases_controller.rb", "before_action -> { require_role!(:reviewer) }\n", "before_action -> { require_role!(:reviewer, :hr_pic, :owner, :consultant) }\n"]],
    tests: %w[test/integration/ai_release_screens_test.rb] },
  { id: "S3", rule: "Found values never echoed outside the text block",
    subs: [["app/views/staff/ai_releases/_findings_summary.html.erb", 'baris <%= lines.join(", ") %>', 'baris <%= lines.map { |l| release.lines[l - 1] }.join(", ") %>']],
    tests: %w[test/integration/ai_release_screens_test.rb] },
  { id: "S4", rule: "A declined CV is listed by person for the manual decision (job page)",
    subs: [["app/views/staff/jobs/_screening_failures.html.erb", "board.finalize_errors + board.not_sent", "board.finalize_errors"]],
    tests: %w[test/integration/ai_release_screens_test.rb] },
  { id: "H1", rule: "Run-5 sentences reach the reviewer marked (hints)",
    subs: [["app/models/screening/release_highlights.rb", "blocking_spans(line, i, names, today) + hint_spans(line, i)", "blocking_spans(line, i, names, today)"]],
    tests: %w[test/services/ai_releases/release_gate_test.rb test/integration/ai_release_screens_test.rb] },
  # Test engine run 1 fixes (F09-01, F09-03).
  { id: "F1", rule: "F09-01: the sample path also requires the sample rubric",
    subs: [["app/services/screening/ai_client.rb", "return if redacted_cv == Sample.redacted_cv && rubric_payload == Sample.rubric.payload", "return if redacted_cv == Sample.redacted_cv"]],
    tests: %w[test/services/ai_releases/hardening_test.rb] },
  { id: "F2", rule: "F09-01: call_api refuses content no release approved",
    subs: [["app/services/screening/ai_client.rb", 'raise Errors::Unreleased, "content not approved by a release" unless @approved_content && content.equal?(@approved_content)', ""]],
    tests: %w[test/services/ai_releases/hardening_test.rb] },
  { id: "F3", rule: "F09-01: judge_released sends only a released text found in the database",
    subs: [["app/services/screening/ai_client.rb", 'raise Errors::Unreleased, "no released, unused text with this digest" if Config.review_before_ai?', ""]],
    tests: %w[test/services/ai_releases/hardening_test.rb] },
  { id: "F4", rule: "F09-01: a consumed release is never sent again",
    subs: [["app/services/screening/ai_client.rb", 'raise Errors::Unreleased, "release #{release.id} was already used" if AiReleases.handler_for(release).consumed?(release)', ""]],
    tests: %w[test/services/ai_releases/hardening_test.rb] },
  { id: "F5", rule: "F09-03: consent withdrawal erases the release texts",
    subs: [["app/services/portal/candidate_actions.rb", 'CandidateErasure.call(application: @application, reason: "consent_withdrawn")', ""]],
    tests: %w[test/services/ai_releases/hardening_test.rb] },
  { id: "F6", rule: "F09-03: retention-end erasure writes its record first",
    subs: [["app/services/ai_releases/erase.rb", "AiReleaseErasure.create!(ai_release_id: id, actor: @actor, reason: @reason, note: @note, created_at: Time.current)", "nil"]],
    tests: %w[test/services/ai_releases/hardening_test.rb] },
  # Test engine run 2 fixes (F09-04): one orchestrator erases every copy.
  { id: "E1", rule: "F09-04: AI quotes and report text are erased", subs: [["app/services/candidate_erasure.rb", "        results: erase_results,\n", "        results: 0,\n"]],
    tests: %w[test/services/ai_releases/hardening_test.rb test/engine/ai_release/run2_attack_test.rb] },
  { id: "E2", rule: "F09-04: stage texts are erased (feature 11 Blank)", subs: [["app/services/candidate_erasure.rb", "        stage_texts: erase_stage_texts,\n", "        stage_texts: 0,\n"]],
    tests: %w[test/services/ai_releases/hardening_test.rb test/engine/ai_release/run2_attack_test.rb] },
  { id: "E3", rule: "F09-04: the extracted CV text is erased", subs: [["app/services/candidate_erasure.rb", "        cv_text: erase_cv_text\n", "        cv_text: 0\n"]],
    tests: %w[test/services/ai_releases/hardening_test.rb test/engine/ai_release/run2_attack_test.rb] },
  { id: "E4", rule: "F09-04: the CV file is purged after the commit", subs: [["app/services/candidate_erasure.rb", "{ @application.cv.purge if @application.cv.attached? }", "{ nil }"]],
    tests: %w[test/services/ai_releases/hardening_test.rb] }
].freeze

ROOT = Dir.pwd
copy = Dir.mktmpdir("hk09-mut-")
system("rsync", "-a", "--exclude", "tmp/", "--exclude", "log/", "--exclude", "storage/", "--exclude", ".git/", "#{ROOT}/", "#{copy}/", exception: true)
FileUtils.mkdir_p(%w[tmp/pids tmp/cache log storage].map { |d| File.join(copy, d) })

def run_tests(dir, files)
  output = IO.popen(["bin/rails", "test", *files], chdir: dir, err: %i[child out], &:read)
  [$?.success?, output.lines.grep(/\d+ runs, \d+ assertions/).last.to_s.strip,
   output.scan(/^(?:Failure|Error):\n\S*?#(test_[^\s\[:]+)/).flatten.first(2).map { |t| t[0, 70] }]
end

# An argument that equals an id selects that one mutant only ("A1" no longer also runs A10..A15);
# any other argument is a prefix, so "A" still runs the whole A group.
selected = ARGV.empty? ? MUTATIONS : MUTATIONS.select { |m| ARGV.any? { |arg| m[:id] == arg || (MUTATIONS.none? { |x| x[:id] == arg } && m[:id].start_with?(arg)) } }
begin
  rows = selected.map do |m|
    originals = m[:subs].map(&:first).uniq.to_h { |f| [f, File.read(File.join(copy, f))] }
    begin
      m[:subs].each do |file, from, to|
        path = File.join(copy, file)
        text = File.read(path)
        abort "#{m[:id]}: anchor not found in #{file}: #{from}" unless text.include?(from)
        File.write(path, text.sub(from) { to })
      end
      green, summary, failing = run_tests(copy, m[:tests])
      { **m, verdict: green ? "SURVIVED" : "KILLED", summary:, failing: }
    ensure
      originals.each { |f, text| File.write(File.join(copy, f), text) }
    end
  end
ensure
  FileUtils.rm_rf(copy)
end

puts "| # | Rule | Verdict | Run line (verbatim) | First failing tests |"
puts "|---|---|---|---|---|"
rows.each { |r| puts "| #{r[:id]} | #{r[:rule]} | #{r[:verdict]} | `#{r[:summary]}` | #{r[:failing].join(' ; ')} |" }
exit(rows.all? { |r| r[:verdict] == "KILLED" } ? 0 : 1)
