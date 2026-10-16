# Feature 09 (D51 B), "Pemeriksaan sebelum AI". Renders a release's payload text EXACTLY: the
# characters inside the text block are the characters the API call sends, in order, with nothing
# added or dropped; highlights are <mark> elements around existing characters, and checkboxes carry
# no text. A test compares the block's text content with AiRelease#payload_text byte for byte.
module AiReleasesHelper
  # One payload line with its highlight spans marked. Escapes everything (CV text is untrusted).
  def release_line_html(line, spans)
    out = []
    pos = 0
    Screening::ReleaseHighlights.merged(spans).each do |s|
      out << h(line[pos...s.start]) if s.start > pos
      tone = s.blocking ? "blocking" : "hint"
      out << content_tag(:mark, line[s.start, s.length], class: "release-mark release-mark--#{tone}",
                                                          data: { category: s.category },
                                                          title: Screening::ReleaseHighlights.label(s.category))
      pos = s.start + s.length
    end
    out << h(line[pos..]) if pos < line.length
    safe_join(out)
  end

  # Category summary for OUTSIDE the text block: names and line numbers only, never a value.
  # Returns [[label, blocking, [line numbers 1-based]], ...].
  def release_findings_summary(spans)
    spans.group_by { |s| [s.category, s.blocking] }.map do |(category, blocking), group|
      [Screening::ReleaseHighlights.label(category), blocking, group.map { |s| s.line + 1 }.uniq.sort]
    end.sort_by { |(_, blocking, _)| blocking ? 0 : 1 }
  end

  def release_rate(measure, count, denominator)
    rate = measure.per_100(count, denominator)
    rate ? "#{number_with_precision(rate, precision: 1, separator: ',')} per 100" : nil
  end

  # The <requirements> JSON of the payload itself (lines 1 .. cv_line_start - 4; see
  # Screening::AiClient.user_content), parsed for a readable list. nil when it does not parse:
  # the screen then points at the text block, which is the authority.
  def release_rubric(release)
    JSON.parse(release.lines[1...(release.cv_line_start - 3)].to_a.join("\n"))
  rescue JSON::ParserError
    nil
  end

  def short_sha(sha) = sha.to_s.first(12)
end
