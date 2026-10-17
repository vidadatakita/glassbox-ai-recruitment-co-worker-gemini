module ScreeningReport
  # D53 (GlassBox Team, 2026-10-10 18:3x): the report SHOWS each criterion on 1-5, as the reference report
  # does. Display only: the S1 score 0-100 and every decision stay on the original judgements
  # (Screening::Score reads "met"/"not_met" and 0-3, never this scale). Changing this table changes
  # what the client reads, not who passes.
  #
  #   wajib          terpenuhi (met) = 5, tidak terpenuhi (not_met) = 1
  #   sebaiknya and  0 -> 1, 1 -> 2, 2 -> 4, 3 -> 5
  #   nilai tambah
  #
  # Used by the candidate detail criteria table and the xlsx sheet "Criteria Scoring"; the
  # mapping sentence below is printed under both.
  module CriterionScale
    WAJIB = { "met" => 5, "not_met" => 1 }.freeze
    RATED = { "0" => 1, "1" => 2, "2" => 4, "3" => 5 }.freeze
    RULE = "Scale 1–5 per criterion, for display only: must-have met = 5, not met = 1; " \
           "should-have and nice-to-have 0 = 1, 1 = 2, 2 = 4, 3 = 5. The AI score 0–100 and the decisions " \
           "still use the original judgements.".freeze

    module_function

    # tier: "wajib" | "sebaiknya" | "nilai_tambah"; judgement as stored by feature 06.
    # Raises on anything else: a silent 1 for an unknown judgement would print a wrong score.
    def of(tier, judgement)
      table = tier.to_s == "wajib" ? WAJIB : RATED
      table.fetch(judgement.to_s) { raise ArgumentError, "no 1-5 mapping for #{tier}/#{judgement.inspect}" }
    end
  end
end
