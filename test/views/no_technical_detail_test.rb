require "test_helper"

# Owner, 2026-10-10 and again 2026-10-11: users never see technical details (AI model names,
# prompt versions, token counts, hashes, exception classes). They stay in the records for audit.
# This scans every view and the xlsx builder for code that would print them.
class NoTechnicalDetailTest < ActiveSupport::TestCase
  PRINTED = /<%=[^%]*\b(?:model_id|prompt_version|PROMPT_VERSION|input_tokens|output_tokens|sha256|short_sha|digest|class\.name)\b/
  WORDS = /\b(?:sidik|fingerprint|SHA-256|prompt\s+[a-z0-9]|model AI|AI model|Kode verifikasi|verification code)/i

  test "no view prints a model, prompt version, token count, hash or class name" do
    offenders = Dir[Rails.root.join("app/views/**/*.erb")].flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, i|
        next if line.strip.start_with?("<%#")
        visible = line.gsub(/<%#.*?%>/m, "").gsub(/<input[^>]*type="hidden"[^>]*>/, "").gsub(/data-[a-z0-9-]+="<%=[^"]*"/, "")
        "#{path.sub("#{Rails.root}/", "")}:#{i + 1}" if visible.match?(PRINTED) || visible.gsub(/<%.*?%>/, "").match?(WORDS)
      end
    end
    assert_empty offenders, "technical detail shown to users:\n#{offenders.join("\n")}"
  end

  test "the xlsx footer names no model or prompt" do
    source = File.read(Rails.root.join("app/services/screening_report/build_workbook.rb"))
    footer = source[/def footer.*?\n    end/m]
    refute_match(/model|prompt/, footer.lines.reject { |l| l.strip.start_with?("#") }.join)
  end
end
