# S1 AI screening (feature 06; decision D50; blueprint §4.1-§4.3). The pieces, in pipeline order:
#
#   Screening::Enqueue        consent gate, knockout gate, "is the AI active?" (§4.1 steps 1-2)
#   ScreenParticipationJob    background job with the §4.3 retry policy
#   Screening::Run            one attempt: CV text, redaction, rubric, AI call, quote check, score
#   Screening::Redactor       §4.1 step 3, pattern-based
#   Screening::Rubric         §4.1 step 4: the brief's requirements, nothing else
#   Screening::Score          §4.1 step 5: the score is computed here, in Ruby, never by the model
#   Screening::QuoteCheck     §4.1 step 6
#   Screening::Calibration    §4.1 step 7, D13
#   Screening::Finalize       writes Decisions only when a person or a passed calibration allows it
#   Screening::Review         §4.1 step 8, the reviewer; never the job's consultant
module Screening
  # The AI has no user row. Its ScoreEntry rows carry this actor id, and the database allows id 0
  # only on an entry that names its model and prompt version (CHECK score_entries_ai_actor_names_model).
  # Deliberately 0, not a seeded "system" user: users carry a login and one of the five §1.2 roles,
  # and an AI must hold neither. Plan 2 adds the users foreign key; it must keep 0 out of it.
  AI_ACTOR_ID = 0

  # Bumped whenever the system prompt or the output schema in Screening::AiClient changes, so
  # every ScoreEntry says which instructions produced it (§4.1 step 9).
  # .3 (feature 08, D61/D62): the optional "report" block (last position, education, recent
  # experience, four narrative boxes, label proposal). Criteria and flag unchanged.
  # 2026-10-16.1 (A3, English demo path): the report narratives, the recent-experience sentence
  # and label_reason are asked for in English instead of Indonesian, and the redaction marker the
  # prompt names is [REDACTED]. Schema, criteria, flag and the stored label values unchanged.
  # .2 (16 Oct): Appendix A-structured anchors for ratings 1/2/3 in the system prompt; scale unchanged.
  # .3 (16 Oct, accuracy pass): evidence first (each criterion's quote is generated before its
  # judgement), a stated method per requirement, level words ("advanced", "senior") gate rating 3,
  # ties go to the lower anchor, Indonesian education levels and experience arithmetic, stricter
  # quote rules, a label that must agree with the must-have judgements. Scale, ids, stored values
  # and the report block's keys unchanged.
  # .4 (16 Oct, after the agreement check of .3: 75.4% exact on ratings, 12 of 17 rating
  # disagreements with the AI higher): anchors by what the CV shows (named only = 1, concrete detail
  # below the level asked = 2, the level or scale asked = 3; a single unit is not "several" or "a
  # team"; an implied duty at most 2), one to three verbatim passages per criterion ("quotes", each
  # checked), and the instruction_seen flag. Scale, ids, stored values and the report block unchanged.
  PROMPT_VERSION = "s1-2026-10-17.5"
end
