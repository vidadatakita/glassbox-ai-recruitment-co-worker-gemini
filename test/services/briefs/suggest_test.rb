require "test_helper"

# AI Builder Cup step 01: the AI proposes the brief, Ruby makes it usable, a person decides.
class Briefs::SuggestTest < ActiveSupport::TestCase
  include PortalFactory

  FakeClient = Struct.new(:text, :seen) do
    def generate(system:, schema:, content:)
      self.seen = { system:, schema:, content: }
      Screening::AiClient::Reply.new(model: "uji-model", text:, input_tokens: 10, output_tokens: 20)
    end
  end

  ANSWER = {
    "success_90d" => "Stok tercatat akurat 98%.",
    "activities" => [
      { "description" => "Mencatat barang masuk", "output" => "Laporan harian", "share_percent" => 30 },
      { "description" => "Stock opname", "output" => "Berita acara", "share_percent" => 30 },
      { "description" => "Arsip dokumen", "output" => "Arsip rapi", "share_percent" => 30 }
    ],
    "requirements" => [
      { "tier" => "wajib", "text" => "Pendidikan minimal SMA", "cv_evidence" => "Ijazah", "weight" => 0, "knockout" => "Lulus SMA?" },
      { "tier" => "wajib", "text" => "Pria usia maksimal 30 tahun", "cv_evidence" => "Data diri", "weight" => 0, "knockout" => "Pria?" },
      { "tier" => "sebaiknya", "text" => "Mahir Excel", "cv_evidence" => "Keahlian Excel", "weight" => 1, "knockout" => "Mahir Excel?" },
      { "tier" => "sebaiknya", "text" => "Pengalaman gudang", "cv_evidence" => "Riwayat kerja", "weight" => 2, "knockout" => "" },
      { "tier" => "nilai_tambah", "text" => "Paham suku cadang", "cv_evidence" => "Riwayat kerja", "weight" => 0, "knockout" => "" }
    ]
  }.freeze

  setup do
    @job = Job.create!(title: "Staf Admin Gudang", golongan: 2, client_company: company)
    @actor = staff_user("hr_pic")
  end

  def suggest(text: ANSWER.to_json, client: FakeClient.new(text))
    Screening::Config.stub(:enabled?, true) do
      Screening::Config.stub(:client, client) { Briefs::Suggest.call(job: @job, actor: @actor) }
    end
  end

  test "the proposal is cleaned, stored as proposed, and changes nothing in the brief" do
    client = FakeClient.new(ANSWER.to_json)
    result = suggest(client:)

    assert result.ok?
    payload = result.suggestion.reload.payload
    assert_equal [34, 33, 33], payload["activities"].map { |a| a["share_percent"] }, "shares scaled to exactly 100"
    sebaiknya = payload["requirements"].select { |r| r["tier"] == "sebaiknya" }
    assert_equal [33, 67], sebaiknya.map { |r| r["weight"] }, "weights scaled to exactly 100, in proportion"
    assert_nil sebaiknya.first["knockout"], "a knockout question only on a wajib line"
    refute payload["requirements"].any? { |r| r["text"].include?("Pria") }, "a protected-attribute line is dropped"
    assert_equal 1, payload["dropped"]
    assert payload["requirements"].any? { |r| r["text"] == "Paham suku cadang" }, "'suku cadang' (spare parts) is not 'suku bangsa'"
    assert_equal "uji-model", result.suggestion.model_id

    assert_includes client.seen[:content], "Position: Staf Admin Gudang"
    refute_match(/PT |Rp|gaji/i, client.seen[:content], "no company name or salary is sent")
    assert_empty @job.reload.activities, "the brief itself is untouched until a person saves"
  end

  # 16 Oct 2026: the same filter in English (the demo brief is English). Mutant: drop "female" and
  # "maximum ... age" from Suggest::PROTECTED -> red.
  test "the protected-word filter also catches English wording and leaves English job words alone" do
    ["Female staff preferred", "Maximum age 30", "Must be under 25", "Christian applicants only", "Unmarried candidates", "Minimum height 165 cm"].each do |line|
      assert_match Briefs::Suggest::PROTECTED, line, "#{line.inspect} should be dropped"
    end
    # "Single Page Application" is NOT in the control list: "single" has been in this filter since
    # before 16 Oct (a pre-existing over-drop, reported; the ad scan's rule table does not have it).
    ["Able to lift 25 kg", "Race condition debugging", "Fluent English", "Manages a team of four"].each do |line|
      refute_match Briefs::Suggest::PROTECTED, line, "#{line.inspect} is a job word"
    end
  end

  test "knockout questions the job already has outside the requirements use up the quota of 3" do
    @job.knockout_questions.create!(position: 1, text: "Bersedia kerja shift?")
    @job.knockout_questions.create!(position: 2, text: "Pengalaman 1 tahun?")
    wajib = %w[SMA SIM Shift].map { |w| { "tier" => "wajib", "text" => "Syarat #{w}", "cv_evidence" => "CV", "weight" => 0, "knockout" => "#{w}?" } }
    answer = ANSWER.merge("requirements" => wajib)
    knockouts = suggest(text: answer.to_json).suggestion.requirements.count { |r| r["knockout"] }
    assert_equal 1, knockouts, "2 existing + 1 proposed = 3; BriefCheck refuses more"
  end

  test "the proposal fills the step forms; step 3 keeps the saved compensation" do
    @job.update!(salary_min: 5_200_000, salary_max: 6_000_000)
    suggestion = suggest.suggestion
    step2 = suggestion.form_params("2", @job)
    assert_equal 3, step2["activities"].size
    step3 = suggestion.form_params("3", @job)
    assert_equal "5.200.000", step3["salary_min"]
    form = BriefForm.new(@job, "3", submitted: step3)
    assert_equal ["Pendidikan minimal SMA"], form.requirements("wajib").map(&:last).map { |r| r["text"] }.compact_blank
  end

  test "AI off, a busy provider, or an unreadable answer: a message, nothing stored" do
    Screening::Config.stub(:enabled?, false) { refute Briefs::Suggest.call(job: @job, actor: @actor).ok? }
    busy = Object.new
    def busy.generate(**) = raise(Screening::Errors::Transient.new("api_error", "HTTP 503"))
    assert_match(/busy/, suggest(client: busy).error)
    assert_match(/could not be read/, suggest(text: "bukan json").error)
    assert_equal 0, BriefSuggestion.count
  end

  test "the brief page compares the AI proposal with what the person saved" do
    suggest
    @job.update!(success_90d: "Stok tercatat akurat 98%.")
    @job.activities.create!(description: "Mencatat barang masuk", output: "Laporan harian", share_percent: 34, position: 1)
    @job.activities.create!(description: "Stock opname", output: "Berita acara bulanan", share_percent: 66, position: 2)
    @job.activities.create!(description: "Menerima retur", output: "Log retur", share_percent: 0, position: 3)

    statuses = BriefSuggestionDiff.new(@job).rows.select { |r| r.section != "Requirements" }.to_h { |r| [(r.ai || r.saved)[/\A[^(]+/].strip, r.status] }
    assert_equal({ "Stok tercatat akurat 98%." => :kept, "Mencatat barang masuk" => :kept, "Stock opname" => :changed,
                   "Arsip dokumen" => :dropped, "Menerima retur" => :added }, statuses)
  end

  test "step 4: the competency map is built from the SAVED brief and kept inside the package's stages" do
    refute Screening::Config.stub(:enabled?, true) { Briefs::Suggest.call(job: @job, actor: @actor, step: "4") }.ok?,
           "no saved activities or requirements: nothing to build from"

    @job.update!(package: 2) # Saring: S1 and S5 only (Briefs::StagePlan::CODES)
    @job.activities.create!(description: "Mencatat barang masuk", output: "Laporan harian", share_percent: 100, position: 1)
    answer = { "competencies" => [
      { "name" => "Ketelitian data stok", "layer" => "L4", "stage_code" => "S3", "anchor_1" => "a", "anchor_3" => "b", "anchor_5" => "c", "questions" => "Ceritakan ..." },
      { "name" => "Pengetahuan FIFO", "layer" => "L1", "stage_code" => "S5", "anchor_1" => "a", "anchor_3" => "b", "anchor_5" => "c", "questions" => "Jelaskan ..." },
      { "name" => "Pengetahuan FIFO", "layer" => "L1", "stage_code" => "S1", "anchor_1" => "a", "anchor_3" => "b", "anchor_5" => "c", "questions" => "" },
      { "name" => "Excel", "layer" => "L4", "stage_code" => "S5", "anchor_1" => "a", "anchor_3" => "b", "anchor_5" => "c", "questions" => "" },
      { "name" => "Integritas", "layer" => "I", "stage_code" => "S1", "anchor_1" => "jujur", "anchor_3" => "b", "anchor_5" => "c", "questions" => "x" },
      { "name" => "Penampilan menarik", "layer" => "I", "stage_code" => "S3", "anchor_1" => "a", "anchor_3" => "b", "anchor_5" => "c", "questions" => "" }
    ] }
    client = FakeClient.new(answer.to_json)
    result = Screening::Config.stub(:enabled?, true) do
      Screening::Config.stub(:client, client) { Briefs::Suggest.call(job: @job, actor: @actor, step: "4") }
    end

    assert result.ok?
    rows = result.suggestion.competencies
    assert_equal ["Ketelitian data stok", "Pengetahuan FIFO", "Excel", "Integritas"], rows.map { |r| r["name"] }, "duplicate name and protected line removed"
    assert_equal "S1", rows[2]["stage_code"], "an interview with no questions moves to CV screening (it would fail BriefCheck)"
    assert_equal "S5", rows[0]["stage_code"], "S3 is not in package 2: moved to the package's interview, S5"
    assert_equal "Ceritakan ...", rows[0]["questions"], "an interview stage keeps its questions"
    assert_equal "", rows[3]["questions"], "questions only for interview stages"
    assert_includes client.seen[:content], "Mencatat barang masuk"
    assert_equal 4, result.suggestion.form_params("4", @job)["competencies"].size
  end

  test "step 5: the technical test is drafted from the saved activities and fills the step-5 form" do
    first = @job.activities.create!(description: "Mencatat barang masuk", output: "Laporan harian", share_percent: 60, position: 1)
    second = @job.activities.create!(description: "Stock opname", output: "Berita acara", share_percent: 40, position: 2)
    answer = { "instructions" => "Temukan selisih stok di file studi kasus.", "time_limit_minutes" => 500,
               "answer_types" => %w[xlsx exe],
               "criteria" => [
                 { "activity" => 2, "name" => "Ketepatan selisih", "weight" => 3, "anchor_1" => "a", "anchor_3" => "b", "anchor_5" => "c" },
                 { "activity" => 1, "name" => "Kerapian laporan", "weight" => 1, "anchor_1" => "a", "anchor_3" => "b", "anchor_5" => "c" },
                 { "activity" => 9, "name" => "Aktivitas tidak ada", "weight" => 5, "anchor_1" => "a", "anchor_3" => "b", "anchor_5" => "c" }
               ] }
    client = FakeClient.new(answer.to_json)
    result = Screening::Config.stub(:enabled?, true) do
      Screening::Config.stub(:client, client) { Briefs::Suggest.call(job: @job, actor: @actor, step: "5") }
    end

    test = result.suggestion.test
    assert_equal TechnicalTestCase::DEFAULT_TIME_LIMIT, test["time_limit_minutes"], "500 minutes is outside 1-60"
    assert_equal ["xlsx"], test["answer_types"], "only the allowed answer types"
    assert_equal [second.id, first.id], test["criteria"].map { |c| c["activity_id"] }, "activity numbers become ids; an unknown one is dropped"
    assert_equal [75, 25], test["criteria"].map { |c| c["weight"] }
    assert_includes client.seen[:content], "2. Stock opname"

    form = TestCaseForm.new(@job, nil, submitted: result.suggestion.form_params("5", @job))
    assert_equal "Temukan selisih stok di file studi kasus.", form.value("instructions")
    assert form.answer_type?("xlsx")
    assert_equal 100, form.total_weight
  end

  test "each tier can use its own model and thinking level (FLOW §9)" do
    env = { "AI_PROVIDER" => "gemini", "AI_MODEL" => "gemini-4-argon", "AI_MODEL_MEDIUM" => "gemini-3.5-flash-lite", "AI_THINKING" => "high", "AI_THINKING_MEDIUM" => "low",
            "AI_MODEL_HIGH" => nil, "AI_THINKING_HIGH" => nil }
    with_env(env) do
      assert_equal ["gemini-4-argon", "high"], [Screening::Config.model(:screening), Screening::Config.thinking(:screening)]
      assert_equal ["gemini-3.5-flash-lite", "low"], [Screening::Config.model(:brief), Screening::Config.thinking(:brief)]
    end
  end
end
