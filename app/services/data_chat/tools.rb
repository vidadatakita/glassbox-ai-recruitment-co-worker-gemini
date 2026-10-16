module DataChat
  # The ONLY data the "Ask AI" assistant can reach: a fixed list of read functions, like stored
  # procedures. The AI picks one by name and fills its typed arguments; it never writes SQL. Each
  # function:
  #   - runs inside a READ ONLY transaction (Tools.run): PostgreSQL itself refuses any write;
  #   - sees only the jobs the user may see (Job.visible_to), and refuses a job_id outside them;
  #   - returns counts, scores, stage names, job titles and "Candidate NN" labels: never a name,
  #     contact, CV text, interviewer or decision note, salary expectation or address.
  module Tools
    class Refused < StandardError; end

    STAGE = CandidateStatus::STAGE_LABELS

    DEFS = {
      "daftar_lowongan" => { about: "List of VACANCIES (not of applicants): id, title, portal state (open = accepting applications), brief state, applicant count.", args: [] },
      "daftar_pelamar" => { about: "Who the applicants are: each applicant as a candidate label (Candidate NN), their vacancy, stage and status; status (optional) filters: lolos (passed every stage), tidak_lolos (did not pass), berjalan (still in process). The app shows names by access rights, never the AI.", args: %w[job_id status] },
      "corong_pelamar" => { about: "Per stage: participants, passed / Continue, Do not continue, still in process.", args: %w[job_id] },
      "menunggu_tindakan" => { about: "What is waiting on a person: HR choices (still open, and already below the pass score but not yet confirmed), interview assessors, test scoring, CVs held back.", args: %w[job_id] },
      "ringkasan_screening" => { about: "AI CV screening results: score distribution, must-have requirements met, proposed labels.", args: %w[job_id] },
      "celah_syarat" => { about: "Per vacancy requirement: how many CVs meet it, partly meet it, or do not (every vacancy when none is named).", args: %w[job_id] },
      "waktu_proses" => { about: "Median hours from the application coming in to the HR choice at each stage.", args: %w[job_id] },
      "saluran_pelamar" => { about: "Applicants and gate passes per channel (direct, LinkedIn, ...).", args: %w[job_id] },
      "keputusan_vs_ai" => { about: "HR choices per stage: Continue / Do not continue and how many followed the AI advice.", args: %w[job_id] },
      "status_kandidat" => { about: "One candidate (the NN of the candidate label in one vacancy): stage, score, AI advice, HR choice. No name.",
                             args: %w[job_id candidate_number], job_required: true }
    }.freeze

    module_function

    # Validates the AI's plan and runs the function read-only. jobs: Job.visible_to(user).
    def run(name, args, jobs:)
      raise Refused, "Unknown function." unless DEFS.key?(name)

      args = (args || {}).to_h.slice(*DEFS[name][:args])
      job = resolve_job(args["job_id"], jobs, required: DEFS[name][:job_required])
      scope = job ? Job.where(id: job.id) : jobs
      read_only { send("t_#{name}", scope, job, args) }
    end

    def resolve_job(raw, jobs, required:)
      return nil if raw.blank? && !required
      raise Refused, "Name the vacancy you mean." if raw.blank?

      id = Integer(raw.to_s, exception: false) or raise(Refused, "Unknown vacancy.")
      jobs.find_by(id:) or raise(Refused, "Vacancy not found in your organisation.")
    end

    # A savepoint with transaction_read_only on: PostgreSQL refuses INSERT/UPDATE/DELETE inside it;
    # rolled back afterwards, which also restores the setting for an enclosing transaction.
    def read_only
      result = nil
      ActiveRecord::Base.transaction(requires_new: true) do
        ActiveRecord::Base.connection.execute("SET LOCAL transaction_read_only = on")
        result = yield
        raise ActiveRecord::Rollback
      end
      result
    end

    def apps(scope) = JobApplication.where(job_id: scope.select(:id))
    def parts(scope) = Participation.joins(:stage).where(stages: { job_id: scope.select(:id) })

    def t_daftar_lowongan(scope, _job, _args)
      counts = JobApplication.where(job_id: scope.select(:id)).group(:job_id).count
      portal = { never_opened: "never opened", open: "open (accepting applications)", closed_by_hr: "closed by HR",
                 closed_by_date: "closed automatically (date)", closed_by_quota: "closed (quota full)",
                 closed_by_stage: "closed (CV screening done)", closed_by_settings: "held (settings incomplete)" }
      scope.order(:id).map do |j|
        { job_id: j.id, judul: j.title, portal: portal.fetch(ApplicationWindow.new(j).state),
          brief: j.brief_status == "complete" ? "complete" : "draft", pelamar: counts.fetch(j.id, 0) }
      end
    end

    # Labels, never names: the chat window shows each person's name itself, only where the viewer
    # may see it (CandidateIdentity), from application_id.
    LIST_LIMIT = 100

    # status: "lolos" = passed every stage (CandidateStatus tone success), "tidak_lolos" = out
    # (danger), "berjalan" = still in a stage; the code filters, never the AI.
    STATUS_TONES = { "lolos" => %w[success], "tidak_lolos" => %w[danger], "berjalan" => %w[info] }.freeze

    def t_daftar_pelamar(scope, _job, args)
      tones = STATUS_TONES[args["status"].to_s]
      apps = apps(scope).where.not(candidate_id: nil).includes(:job).order(:job_id, :id).limit(LIST_LIMIT * 3).to_a
      rows = apps.filter_map do |a|
        summary = CandidateStatus.new(a).summary
        next if tones && !tones.include?(summary.tone)

        { application_id: a.id, kandidat: CandidateIdentity.label(a), lowongan: a.job.title, status: summary.text }
      end.first(LIST_LIMIT)
      { saringan: args["status"].presence || "all", jumlah: rows.size, pelamar: rows }
    end

    def t_corong_pelamar(scope, _job, _args)
      rows = parts(scope).includes(:stage, :progression_choice).to_a
      rows.group_by { |p| p.stage.code }.sort_by { |code, _| Stage::CODES.index(code) }.map do |code, group|
        decisions = Decision.current.where(participation_id: group.map(&:id)).pluck(:participation_id, :outcome).to_h
        { tahap: STAGE.fetch(code), peserta: group.size,
          lanjut: group.count { |p| p.progression_choice&.direction == "lanjut" || (decisions[p.id] == "pass" && p.progression_choice.nil?) },
          tidak_lanjut: group.count { |p| p.progression_choice&.direction == "tidak_lanjut" || decisions[p.id] == "eliminate" },
          berjalan: group.count { |p| p.progression_choice.nil? && !%w[pass eliminate].include?(decisions[p.id]) } }
      end
    end

    def t_menunggu_tindakan(scope, _job, _args)
      steps = parts(scope).includes(:stage, :progression_choice).select { |p| Progression.step?(p) && p.progression_choice.nil? }
      # A gate step is out when either of its stages is (Gates::Result), like the job page counts it.
      below, waiting = steps.partition { |p| Progression.step_members(p).any? { |m| m.current_decision&.outcome == "eliminate" } }
      # Two numbers, so the answer matches the job page: the ones still open, and the ones already
      # below the threshold (or out by rule) that nobody has confirmed yet.
      { menunggu_pilihan_hr: waiting.size, belum_dipilih_tetapi_sudah_di_bawah_ambang: below.size,
        penilai_wawancara_belum_mengisi: InterviewerInvite.where(participation_id: parts(scope).select(:id), submitted_at: nil).count,
        jawaban_tes_belum_dinilai: TestAttempt.joins(participation: :stage).where(stages: { job_id: scope.select(:id) })
                                              .where.not(answered_at: nil).where.missing(:review).count,
        cv_ditahan_untuk_pemeriksaan: parts(scope).where(screening_state: "awaiting_release").count }
    end

    def t_ringkasan_screening(scope, _job, _args)
      results = ScreeningResult.current_for(parts(scope).where(stages: { code: "S1" }).select(:id)).to_a
      return { cv_dinilai: 0 } if results.empty?

      { cv_dinilai: results.size,
        sebaran_skor: { "0-39" => results.count { |r| r.score < 40 }, "40-59" => results.count { |r| r.score.between?(40, 59.99) },
                        "60-79" => results.count { |r| r.score.between?(60, 79.99) }, "80-100" => results.count { |r| r.score >= 80 } },
        median_skor: median(results.map { |r| r.score.to_f }),
        syarat_wajib_terpenuhi: results.count(&:wajib_met),
        usulan_label: results.group_by(&:label_proposal).transform_keys { |k| k ? ScreeningReport::Labels.word(k) : "no label" }.transform_values(&:size) }
    end

    # Per job, so the same wording in two jobs is never counted as one requirement; the job's title
    # on each row when no job was named. Most often unmet first.
    def t_celah_syarat(scope, job, _args)
      scope.order(:id).flat_map do |each_job|
        results = ScreeningResult.current_for(parts(Job.where(id: each_job.id)).where(stages: { code: "S1" }).select(:id)).to_a
        results.flat_map(&:criteria).group_by { |c| c["text"] }.map do |text, rows|
          tally = rows.map { |r| r["judgement"].to_s }.tally
          { lowongan: (each_job.title unless job), syarat: text, tingkat: rows.first["tier"], dinilai: rows.size,
            terpenuhi: tally.slice("met", "3", "2").values.sum, sebagian: tally.fetch("1", 0), tidak: tally.slice("not_met", "0").values.sum }.compact
        end
      end.sort_by { |row| -row[:tidak] }
    end

    def t_waktu_proses(scope, _job, _args)
      choices = ProgressionChoice.joins(participation: [:stage, :job_application]).where(stages: { job_id: scope.select(:id) })
                                 .pluck("stages.code", "progression_choices.created_at", "job_applications.created_at")
      choices.group_by(&:first).sort_by { |code, _| Stage::CODES.index(code) }.map do |code, rows|
        { tahap: STAGE.fetch(code), pilihan: rows.size, median_jam_sejak_melamar: median(rows.map { |_, chosen, applied| ((chosen - applied) / 1.hour).round(1) }) }
      end
    end

    def t_saluran_pelamar(scope, _job, _args)
      apps(scope).includes(participations: %i[stage progression_choice]).group_by { |a| a.channel_code.presence || "direct" }.map do |channel, group|
        { saluran: channel, pelamar: group.size,
          lolos_gerbang: group.count { |a| a.participations.any? { |p| p.stage.code == "S1" && p.progression_choice&.direction == "lanjut" } } }
      end
    end

    def t_keputusan_vs_ai(scope, _job, _args)
      choices = ProgressionChoice.joins(participation: :stage).where(stages: { job_id: scope.select(:id) }).includes(:stage_recommendation, participation: :stage)
      choices.group_by { |c| c.participation.stage.code }.map do |code, group|
        with_ai = group.select { |c| c.stage_recommendation&.ready? }
        { tahap: STAGE.fetch(code), pilihan: group.size, lanjut: group.count { |c| c.direction == "lanjut" },
          tidak_lanjut: group.count { |c| c.direction == "tidak_lanjut" }, dengan_rekomendasi_ai: with_ai.size,
          sejalan_dengan_ai: with_ai.count { |c| c.direction == c.stage_recommendation.advice } }
      end
    end

    def t_status_kandidat(scope, job, args)
      number = Integer(args["candidate_number"].to_s.sub(/\D*/, ""), exception: false) or raise(Refused, "Name the candidate number, for example Candidate 03.")
      ids = JobApplication.where(job_id: job.id).where.not(candidate_id: nil).order(:id).pluck(:id)
      application = JobApplication.find_by(id: ids[number - 1]) if number.between?(1, ids.size)
      raise Refused, "Candidate #{format('%02d', number)} does not exist in this vacancy." unless application

      { kandidat: CandidateIdentity.label(application), lowongan: job.title,
        tahap: application.participations.includes(:stage, :progression_choice).sort_by { |p| Stage::CODES.index(p.stage.code) }.map do |p|
          rec = StageRecommendation.latest_for(p)
          { tahap: STAGE.fetch(p.stage.code), skor: p.current_score&.to_f, ambang: p.stage.threshold.to_f,
            saran_ai: (rec.advice_label if rec&.ready?), pilihan_hr: p.progression_choice&.label }
        end }
    end

    def median(values)
      return nil if values.empty?

      sorted = values.sort
      mid = sorted.size / 2
      (sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0).round(1)
    end
  end
end
