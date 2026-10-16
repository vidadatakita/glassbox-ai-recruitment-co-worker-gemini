# Background S1 screening of one participation (blueprint §1.1 tech line: Solid Queue; §4.3).
#
# Retry policy, from §4.3, counted in ATTEMPTS (the first run plus the retries):
#   - timeout, connection error, 429, 5xx (Errors::Transient): 3 retries with increasing wait
#     (polynomially longer: about 3 s, 18 s, 83 s), so 4 attempts in all;
#   - malformed model output (Errors::Malformed): 1 retry, so 2 attempts;
#   - refusal after the server-side fallback, or a request the API rejects (Errors::Permanent):
#     no retry.
# When the retries are spent, or at once for a permanent failure, the participation becomes
# "screening_failed" ("Screening gagal"), visible in Antrean Kerja and on the job page. NO score
# entry is written on any failure path, and no default score is ever invented.
#
# The argument is the participation id only, never CV text or personal data (ONP-19: job
# arguments are written to the queue tables and the log).
class ScreenParticipationJob < ApplicationJob
  queue_as :default

  retry_on Screening::Errors::Transient, attempts: 4, wait: :polynomially_longer do |job, error|
    job.mark_failed(error)
  end
  retry_on Screening::Errors::Malformed, attempts: 2, wait: 5.seconds do |job, error|
    job.mark_failed(error)
  end
  discard_on ActiveRecord::RecordNotFound

  def perform(participation_id)
    participation = Participation.find(participation_id)
    Screening::Run.call(participation, attempt: executions)
  rescue Screening::Errors::Permanent => e
    Screening::Run.fail!(participation, e, attempt: executions)
  rescue Screening::Errors::Transient, Screening::Errors::Malformed
    raise # retry_on above owns these
  rescue StandardError => e
    # Anything unexpected (a bug, an SDK change, a database error) must not leave the CV in
    # "Dalam antrean" forever with nothing on screen (§4.3; test engine run 1, F-04). Recorded as
    # an attempt and as "Screening gagal" with the error CLASS only (never a message that could
    # echo CV text), then re-raised so the queue's failed-job record and the log show it too.
    raise unless participation

    # The result was already stored (the error came after, e.g. in Finalize): the score stands, so
    # the screen must NOT say "Screening gagal. Tidak ada skor yang dibuat.", and "Mulai screening"
    # must not call the API again for it (test engine run 2, F-14). The state stays "done" with a
    # finalize error shown; "Mulai screening" retries only Finalize.
    if participation.reload.screening_state == "done"
      participation.update!(screening_failure: "finalize", screening_failure_detail: e.class.name,
                            screening_state_at: Time.current)
      Rails.logger.warn("[screening] participation=#{participation.id} finalize error #{e.class.name}")
      raise
    end

    unexpected = Screening::Errors::Permanent.new("unexpected", e.class.name)
    ScreeningAttempt.create!(participation:, attempt: executions, outcome: "failed", error_kind: unexpected.kind,
                             detail: unexpected.detail, created_at: Time.current)
    Screening::Run.fail!(participation, unexpected, attempt: executions)
    raise
  end

  def mark_failed(error)
    participation = Participation.find_by(id: arguments.first)
    Screening::Run.fail!(participation, error, attempt: executions) if participation
  end
end
