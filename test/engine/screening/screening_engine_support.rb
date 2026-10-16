# Shared helpers for the feature-06 test engine (S1 AI screening). Written by the test engine on
# 2026-10-10. The builder's ScreeningFactory (FakeGemini at the HTTP boundary) is reused, never
# changed. Everything here is invented data; no real person.
#
# Spec oracles are written out literally from the documents (blueprint §4.1, §4.3, D13), never read
# from the constants under test: a test that takes its expected value from the code it checks
# cannot go red.
module ScreeningEngineSupport
  include ActiveJob::TestHelper
  include ScreeningFactory

  # Blueprint §4.3, counted in API calls: timeout/error -> 1 + 3 retries; malformed -> 1 + 1.
  SPEC_TRANSIENT_CALLS = 4
  SPEC_MALFORMED_CALLS = 2
  # D13: rubric must be fixed when AI and consultant disagree on MORE THAN 15% of the first 20.
  SPEC_CALIBRATION_SIZE = 20
  SPEC_MAX_DISAGREEMENTS_THAT_PASS = 3 # 3/20 = 15%, not more than 15%

  # D51 re-baseline (2026-10-10 19:xx, feature 09). Every CV now stops at "Menunggu pemeriksaan"
  # until a named reviewer presses "Kirim ke AI". The engine releases through the REAL path,
  # AiReleases::Release (role check, consultant check, the tick, the digest the reviewer saw, the
  # residual-finding refusal, every feature-06 gate re-checked), as a dedicated reviewer who is never
  # a job's consultant in these tests. A version with residual findings is never released (it stays
  # unsent, which the engine's "blocked" classification already counts as not sent). A refusal is
  # the gate working and is recorded in @release_refusals, never swallowed silently.
  RELEASER_EMAIL = "pemeriksa-ai@uji.example".freeze

  def releaser = staff_user("reviewer", email: RELEASER_EMAIL)

  def release_refusals = (@release_refusals ||= [])

  # Releases every clean, pending, latest version. Returns how many were released.
  def release_clean_held!
    released = 0
    Participation.where(screening_state: "awaiting_release").order(:id).each do |participation|
      release = AiRelease.latest_for(participation)
      next if release.nil? || !release.pending? || release.residual?

      begin
        AiReleases::Release.call(release:, user: releaser, confirmed: "1", seen_sha256: release.payload_sha256)
        released += 1
      rescue AiReleases::Refused => e
        release_refusals << [participation.id, e.message]
      end
    end
    released
  end

  # Runs the screening job and every retry it schedules, as Solid Queue would, without waiting;
  # releases clean held texts in between (release: false keeps them held).
  def drain_jobs!(release: true)
    30.times do
      ran = enqueued_jobs.any?
      perform_enqueued_jobs(at: 1.year.from_now) if ran
      released = release ? release_clean_held! : 0
      break if !ran && released.zero?
    end
  end

  # The builder's calibrate! keeps release: false by default; the engine's calibrations release.
  def calibrate!(job, fake, **kwargs) = super(job, fake, **kwargs, release: true)

  # Applies with the AI ON and the fake installed, replaces the stored CV text with `cv_text`
  # (Screening::Run prefers stored text, so the exact variant reaches the redactor without PDF
  # extraction noise), then runs the job. Returns [participation, fake].
  def screen_text!(job, cv_text, replies: nil, name: CANDIDATE_NAME)
    fake = FakeGemini.new
    with_ai(fake) do
      fake.push(*(replies || [gemini_message(criteria_for(job))]))
      participation = apply_with_cv!(job, name:)
      participation.job_application.update!(cv_text:, cv_text_source: "pdf", cv_text_at: Time.current)
      drain_jobs!
      [participation.reload, fake]
    end
  end

  # Every string inside the parsed JSON body (system prompt, messages, schema, keys and values),
  # joined, so a value split by JSON escaping is still found. Used together with the raw body.
  def body_strings(raw)
    out = []
    walk = lambda do |node|
      case node
      when Hash then node.each { |k, v| out << k.to_s; walk.call(v) }
      when Array then node.each { |v| walk.call(v) }
      else out << node.to_s
      end
    end
    walk.call(JSON.parse(raw))
    out.join("\n")
  end

  # The values (from `values`) that reached the outgoing request: raw body or parsed strings.
  #
  # Oracle fix 2026-10-10 20:xx ("oracle matched requirement ids"): the rubric in the body carries
  # ids "R<requirement id>" from a database sequence that rollbacks never reset, so a protected
  # number ("158", "1995", "3456") matched an id like R158 once the sequence reached it (shown by the
  # feature-09 builder; reproduced by the engine with the sequence forced to 156, 1993 and 3454).
  # Those id tokens are masked before the check; everything else in the body is still searched.
  RUBRIC_ID = /\bR\d+\b/

  def mask_rubric_ids(text) = text.gsub(RUBRIC_ID, "R#")

  def leaked(raw_body, values)
    raw = mask_rubric_ids(raw_body)
    text = mask_rubric_ids(body_strings(raw_body))
    values.select { |v| raw.include?(v) || text.include?(v) }
  end

  # Criteria with per-key overrides: { key => { judgement:, quote: } }.
  def criteria_with(job, overrides = {}, **defaults)
    criteria_for(job, **defaults).map { |c| overrides.key?(c[:id]) ? c.merge(overrides[c[:id]]) : c }
  end

  def keys_of(job, tier) = Screening::Rubric.for(job).criteria.select { |c| c.tier == tier }.map(&:key)

  # Calibrates the job with 20 passes (0 disagreements) and opens S1, so results may become
  # decisions. Returns the 20 participations.
  def calibrated_open_job!(job, fake)
    Stages::Open.call(stage: s1(job))
    with_ai(fake) { calibrate!(job, fake) }
  end

  def gemini_error(status, type)
    [status, { type: "error", error: { type:, message: "uji" } }]
  end
end
