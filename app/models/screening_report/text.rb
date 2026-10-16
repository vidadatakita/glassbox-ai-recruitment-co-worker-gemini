module ScreeningReport
  # Display text shared by the report screen and the xlsx, so both say the same thing. English,
  # WIB, integer rupiah with dot separators.
  module Text
    module_function

    def rupiah(amount) = "Rp#{amount.to_i.to_s.reverse.scan(/\d{1,3}/).join('.').reverse}"

    def salary(min, max)
      return "—" if min.nil? || max.nil?

      min == max ? rupiah(min) : "#{rupiah(min)}–#{rupiah(max).delete_prefix('Rp')}"
    end

    # Compact form for the list and the xlsx, as the reference report writes it: "Rp7–8 jt",
    # "Rp7,5–9 jt". Millions with at most one decimal; the detail page shows the full rupiah.
    def salary_short(min, max)
      return "—" if min.nil? || max.nil?

      jt = ->(v) { format("%.1f", v / 1_000_000.0).sub(/\.0\z/, "").sub(".", ",") }
      min == max ? "Rp#{jt.(min)} jt" : "Rp#{jt.(min)}–#{jt.(max)} jt"
    end

    def score(value) = value.nil? ? nil : format("%.1f", value).sub(".", ",").sub(/,0\z/, "")

    def band(value) = value.nil? ? "—" : "#{value}/5"

    def appointment(appointment)
      return "—" if appointment.nil?

      stage = Briefs::StagePlan::LABELS.fetch(appointment.participation.stage.code, appointment.participation.stage.code)
      "#{stage} · #{I18n.l(appointment.starts_at.in_time_zone('Asia/Jakarta'), format: '%-d %b %Y %H.%M')} WIB"
    end

    def recommendation(rec)
      rec.nil? ? "—" : "#{UserRecommendation::PICKS.fetch(rec.pick).first} · #{rec.user_name}"
    end

    def label(row)
      return "None yet" if row.label_key.nil?

      "#{Labels.word(row.label_key)} (#{row.label_confirmed ? 'confirmed by reviewer' : 'AI advice'})"
    end

    # The AI's original judgement in words (feature 06 scale), beside the D53 1-5.
    def judgement(tier, judgement)
      return judgement.to_s == "met" ? "Met" : "Not met" if tier.to_s == "wajib"

      "#{judgement} of 3"
    end

    def test(cell) = cell.state == :scored ? score(cell.score) : cell.label

    def last_position(result)
      text = result&.last_position.is_a?(Hash) ? result.last_position["text"].to_s.strip : ""
      text.empty? ? "—" : text
    end
  end
end
