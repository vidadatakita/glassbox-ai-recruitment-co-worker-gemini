# frozen_string_literal: true

module Scoring
  # Statistics shown at the top of every stage scoreboard (blueprint §2.2 rules 5 and 9).
  #
  # Callers pass CURRENT rows only (latest non-superseded score and decision). No-shows and
  # withdrawals are counted but never averaged in: averaging a no-show as 0 would drag the
  # average down and make the stage look harder than it was.
  module StageStats
    Row = Data.define(:attendance, :score, :outcome)
    Summary = Data.define(:participants, :passed, :eliminated, :no_shows, :in_review, :average, :median)

    module_function

    def call(rows)
      attended = rows.select { |r| r.attendance == :attended }
      scores = attended.filter_map { |r| r.score&.to_r }

      Summary.new(
        participants: rows.size,
        passed: rows.count { |r| r.outcome == :pass },
        # Every elimination except a no-show, which has its own bucket (rule 5). A withdrawal is an
        # elimination by rule (Decider), so it counts here; before 2026-10-10 it was counted in no
        # bucket and the stage's figures did not add up to its participants (test engine F-12).
        eliminated: rows.count { |r| r.outcome == :eliminate && r.attendance != :no_show },
        # A no-show passed by a manual override (rule 4) counts once, as passed; counting it in both
        # buckets made the figures exceed the participants (test engine F-22).
        no_shows: rows.count { |r| r.attendance == :no_show && r.outcome != :pass },
        in_review: rows.count { |r| r.outcome == :review },
        average: scores.empty? ? nil : Rational(scores.sum, scores.size),
        median: median(scores)
      )
    end

    def median(values)
      return nil if values.empty?

      sorted = values.sort
      mid = sorted.size / 2
      # Rational, so median([70, 71]) is 141/2 and not Integer-divided to 70 (test engine F-18).
      sorted.size.odd? ? sorted[mid] : Rational(sorted[mid - 1] + sorted[mid], 2)
    end
  end
end
