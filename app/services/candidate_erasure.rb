# Erases every stored copy of one candidate's CV text (feature 09, F09-04): the ONE entry point for
# consent withdrawal (UU 27/2022 Pasal 40), missing consent (D16) and retention end (D32, blueprint
# §4.2). Portal::CandidateActions#withdraw_consent! and the rake task glassbox:retention:erase_expired
# call only this.
#
# One shape everywhere: for each record, an erasure row (who, why, when) is written FIRST, then the
# text columns are set to NULL in one statement; each table's trigger permits exactly that.
#   1. ai_releases.payload_text                    AiReleases::Erase (ai_release_erasures)
#   2. screening_results quotes and report text    below (screening_result_erasures)
#   3. AI Builder Cup D63 texts (GlassBox Team 2026-10-12 20:28): stage_recommendations.summary/reasons/
#      problem, salary_recommendations.summary/factors/problem, progression_choices.note,
#      salary_agreements.note, score_entries.note        below (stage_text_erasures)
#      NOT erased: the manual Decision note Progression::Choose copies from a choice note
#      (decisions.note is required for a manual decision, feature 01); open item for GlassBox Team.
#   4. job_applications.cv_text                    set to NULL (who pasted and when stay)
#   5. the CV PDF                                  purged AFTER the commit (a file delete cannot be
#                                                  rolled back, so it runs only once the rows are erased)
# Steps 1-4 run in ONE transaction: a refusal anywhere erases nothing. If this is called inside an
# outer transaction (withdraw_consent!), the purge waits for that outer commit.
#
# Kept on purpose: scores, decisions, digests, who released or cut and when, the erasure records,
# and the candidate's name and contacts (those belong to the retention deletion of the person, Plan 6;
# feature record 09 §8). Idempotent: a second call finds nothing to erase.
#
# reason: retention_expired | consent_withdrawn | no_consent. actor: a user, or nil for the system or
# the candidate's own withdrawal. Returns { releases:, results:, stage_texts:, cv_text:, cv_file: }.
class CandidateErasure
  def self.call(**kwargs) = new(**kwargs).call

  def initialize(application:, reason:, actor: nil, note: nil)
    @application = application
    @reason = reason.to_s
    @actor = actor
    @note = note
  end

  def call
    raise ArgumentError, "unknown erasure reason #{@reason.inspect}" unless AiReleaseErasure::REASONS.key?(@reason)

    counts = ActiveRecord::Base.transaction do
      {
        releases: AiReleases::Erase.call(application: @application, reason: @reason, actor: @actor, note: @note),
        results: erase_results,
        stage_texts: erase_stage_texts,
        cv_text: erase_cv_text
      }
    end
    counts[:cv_file] = @application.cv.attached? ? 1 : 0
    ActiveRecord.after_all_transactions_commit { @application.cv.purge if @application.cv.attached? }
    counts
  end

  private

  TEXT_RESULTS = "last_position IS NOT NULL OR education IS NOT NULL OR recent_experience IS NOT NULL OR " \
                 "narratives IS NOT NULL OR label_reason IS NOT NULL OR " \
                 "judgements::text <> screening_judgements_without_quotes(judgements)::text"

  def erase_results
    scope = ScreeningResult.where(participation_id: @application.participations.select(:id)).where(TEXT_RESULTS)
    ids = scope.pluck(:id)
    logged = ScreeningResultErasure.where(screening_result_id: ids).pluck(:screening_result_id)
    (ids - logged).each do |id|
      ScreeningResultErasure.create!(screening_result_id: id, actor: @actor, reason: @reason, note: @note, created_at: Time.current)
    end
    scope.update_all("last_position = NULL, education = NULL, recent_experience = NULL, narratives = NULL, " \
                     "label_reason = NULL, judgements = screening_judgements_without_quotes(judgements)")
  end

  # The AI Builder Cup D63 texts (GlassBox Team 2026-10-12 20:28, "3 build"): recommendation summaries and
  # reasons, salary recommendation summaries and factors, choice notes, salary agreement notes and
  # interviewer score notes. For each record that still holds text: an erasure row first, then the
  # text columns are blanked (the trigger of migration 20261012210000 allows nothing else). Counts
  # only records that still held text, so a second call reports 0.
  def erase_stage_texts
    participation_ids = @application.participations.select(:id)
    StageTextErasure::TEXTS.sum do |table, (model_name, columns)|
      model = model_name.constantize
      scope = model.column_names.include?("participation_id") ? model.where(participation_id: participation_ids) : model.where(job_application_id: @application.id)
      holding = scope.where(columns.keys.map { |c| "#{table}.#{c} IS NOT NULL AND #{table}.#{c}::text NOT IN ('{}', '[]', '#{StageTextErasure::MARKER}')" }.join(" OR "))
      ids = holding.pluck(:id)
      ids.each do |id|
        StageTextErasure.create!(record_type: table, record_id: id, job_application: @application, actor: @actor,
                                 reason: @reason, note: @note, created_at: Time.current)
      end
      model.where(id: ids).update_all(columns) if ids.any?
      ids.size
    end
  end

  def erase_cv_text
    JobApplication.where(id: @application.id).where.not(cv_text: nil).update_all(cv_text: nil)
  end
end
