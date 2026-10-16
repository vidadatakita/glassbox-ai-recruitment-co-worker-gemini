# Test engine, feature 07 slices 1-2 (D60): fixtures owned by the engine, independent of the
# builder's test/support/gate_factory.rb and test_case_factory.rb, so a later change to those
# factories cannot quietly change what these tests prove. Every name and text is invented.
module Engine07Support
  # A gate S1 + S2 (+ S5) built directly on the stage table, the way Briefs::SyncStages leaves it
  # for package 3: both drafts, gate "screening".
  def e7_gated_job(s1_threshold: 60, s2_threshold: 60, title: "Kepala Regu Uji E7")
    job = Job.create!(title:, golongan: 3, client_company: company)
    s1 = job.stages.create!(code: "S1", score_source: "ai", weight: 10, threshold: s1_threshold, gate: "screening")
    s2 = job.stages.create!(code: "S2", score_source: "manual_or_import", weight: 20, threshold: s2_threshold, gate: "screening")
    job.stages.create!(code: "S5", score_source: "scorecard", weight: 70, threshold: 70)
    [job, s1, s2]
  end

  def e7_open_gate!(s1)
    Gates::Open.call(stage: s1)
    s1.job.stages.reload
  end

  # One applicant in both gate stages, as Lamar enters them; a named candidate when a name is given.
  def e7_applicant(s1, s2, name: nil)
    candidate = name && Candidate.create!(name:, email: "#{name.split.first.downcase}.e7@uji.example", phone: "081234567890")
    application = if candidate
                    JobApplication.create!(job: s1.job, candidate:, consent_at: Time.current,
                                           consent_template: publish_consent, consent_retention_days: 30)
                  else
                    JobApplication.create!(job: s1.job)
                  end
    [Participation.create!(job_application: application, stage: s1, attendance: "attended"),
     Participation.create!(job_application: application, stage: s2, attendance: "pending")]
  end

  def e7_score!(participation, value)
    ScoreEntry.create!(participation:, value:, entered_by_id: 1, event_at: Time.current, entered_at: Time.current)
  end

  def e7_decide!(participation, outcome, basis: "threshold", reason: nil, note: nil, supersedes: :current)
    reason ||= { "pass" => "at_or_above_threshold", "eliminate" => "below_threshold", "review" => "below_threshold" }[outcome]
    supersedes = participation.current_decision if supersedes == :current
    Decision.create!(participation:, outcome:, basis:, reason_code: reason, note:, decided_by_id: 1,
                     decided_at: Time.current, supersedes:)
  end

  def e7_scored!(participation, value, outcome)
    participation.update!(attendance: "attended") unless participation.attendance == "attended"
    e7_score!(participation, value)
    e7_decide!(participation, outcome)
  end

  def gate_rows(participation) = Decision.where(participation:, reason_code: "gate_eliminated")

  # ---- technical test definition --------------------------------------------------------------
  def e7_xlsx(rows = [["Kode", "Qty"], ["BRG-07", 7]])
    require "caxlsx"
    package = Axlsx::Package.new
    package.workbook.add_worksheet(name: "Kasus") { |sheet| rows.each { |r| sheet.add_row(r) } }
    package.to_stream.read
  end

  def e7_upload(bytes, name, type = "application/octet-stream")
    Rack::Test::UploadedFile.new(StringIO.new(bytes.b), type, original_filename: name)
  end

  def e7_params(job, weights: [50, 50], file: :default, activity_ids: nil, **overrides)
    file = e7_upload(e7_xlsx, "kasus-e7.xlsx") if file == :default
    ids = activity_ids || job.activities.map(&:id)
    params = { instructions: "Cari selisih stok dan tulis koreksinya.", time_limit_minutes: "35",
               answer_types_submitted: "1", answer_types: %w[xlsx pdf],
               criteria: weights.each_with_index.to_h do |w, i|
                 [i.to_s, { activity_id: ids[i % ids.size].to_s, name: "Kriteria E7 #{i + 1}", weight: w.to_s,
                            anchor_1: "Tidak ditemukan", anchor_3: "Sebagian", anchor_5: "Semua dan dijelaskan" }]
               end }
    params[:case_file] = file if file
    params.merge(overrides)
  end

  def e7_save(job, actor: staff_user("consultant"), **kwargs)
    TestCases::SaveVersion.call(job:, actor:, params: e7_params(job, **kwargs))
  end

  def e7_approved!(job)
    saved = e7_save(job)
    assert saved.ok?, "engine fixture: save refused #{saved.errors.inspect}"
    approved = TestCases::Approve.call(test_case: saved.test_case, actor: staff_user("hr_pic"))
    assert approved.ok?, "engine fixture: approval refused #{approved.errors.inspect}"
    saved.test_case.reload
  end

  # A brief through step 4 for package 3 with NO test case (the builder's factory is called with
  # test_case: false, which this engine pins below as still meaning "none").
  def e7_brief(package: 3, golongan: 3)
    briefed_job(golongan:, package:, complete: false, test_case: false)
  end

  # Raw SQL in a savepoint; returns the error or nil. Never leaves the test transaction aborted.
  def e7_sql_error(sql)
    ActiveRecord::Base.transaction(requires_new: true) { ActiveRecord::Base.connection.execute(sql) }
    nil
  rescue ActiveRecord::StatementInvalid => e
    e
  end
end
