# Shared helpers for the feature-03 test engine (job form "Buat Lowongan"). Written by the test
# engine on 2026-10-10. The builder's helpers (BriefFactory, PortalFactory, ScoringFactory) are
# reused and never changed. The portal engine's helpers are COPIED here, not required, so this
# directory's hashes (docs/test-engine/hashes-03.txt) cover everything these tests depend on.
#
# Spec oracles are written out literally below, from the documents, never derived from the
# constants under test (Briefs::Coverage::REQUIRED, Briefs::StagePlan::CODES, PackageAdvisor):
# a test that reads its expected value from the code it checks cannot go red.
module JobFormEngineSupport
  # Blueprint §2.3 "Required coverage by Golongan" (✓ = at least one competency in the layer),
  # copied cell by cell from BLUEPRINT-T1-2026-09-27.md lines 182-189.
  SPEC_COVERAGE = {
    "L1" => { "G1-2" => true,  "G3" => true,  "G4-5" => true,  "G6-8" => false },
    "L2" => { "G1-2" => false, "G3" => true,  "G4-5" => true,  "G6-8" => true },
    "L3" => { "G1-2" => false, "G3" => false, "G4-5" => true,  "G6-8" => true },
    "L4" => { "G1-2" => true,  "G3" => true,  "G4-5" => true,  "G6-8" => false },
    "L5" => { "G1-2" => false, "G3" => true,  "G4-5" => true,  "G6-8" => true },
    "I"  => { "G1-2" => true,  "G3" => true,  "G4-5" => true,  "G6-8" => true }
  }.freeze
  GOLONGAN_COLUMN = { 1 => "G1-2", 2 => "G1-2", 3 => "G3", 4 => "G4-5", 5 => "G4-5", 6 => "G6-8", 7 => "G6-8", 8 => "G6-8" }.freeze

  # Blueprint §7.1 "Recommended package": "2 Saring or 3 Seleksi" / "3 Seleksi" /
  # "4 Seleksi Lengkap" / "4 or 5 Tuntas".
  SPEC_PACKAGES = { 1 => [2, 3], 2 => [2, 3], 3 => [3], 4 => [3], 5 => [3], 6 => [3], 7 => [3], 8 => [3] }.freeze

  # Concept brief §3 ladder (scored stages) plus the reference check for packages 4-5 (§3.4).
  SPEC_STAGES = {
    1 => %w[S5], 2 => %w[S1 S5], 3 => %w[S1 S2 S3 S5],
    4 => %w[RC S1 S2 S3 S4 S5], 5 => %w[RC S1 S2 S3 S4 S5]
  }.freeze

  def spec_required_layers(golongan)
    SPEC_COVERAGE.select { |_, cols| cols.fetch(GOLONGAN_COLUMN.fetch(golongan)) }.keys
  end

  # The wizard step-4 params with competencies on the given layers, each owned by a stage the
  # package runs (S3 when present, else the first scored stage).
  def competencies_for(layers, package)
    codes = Briefs::StagePlan.scored_codes(package)
    stage = codes.include?("S3") ? "S3" : codes.first
    layers.each_with_index.to_h do |layer, i|
      [i.to_s, { name: "Kompetensi #{layer} #{i}", layer:, stage_code: stage, anchor_1: "Hasil perlu diulang",
                 anchor_3: "Sesuai standar", anchor_5: "Sesuai standar dan memperbaiki cara", questions: "Ceritakan contohnya." }]
    end
  end

  def run_step(job, step, params, actor: staff_user("hr_pic"))
    Briefs::SaveStep.call(job:, step:, params:, actor:)
  end

  # Opens one draft stage of the job (Stages::Open is the scoring core's lock trigger, rule 3).
  def open_stage!(job, code = nil)
    stage = code ? job.stages.find_by!(code:) : job.stages.order(:code).where(status: "draft").first!
    Stages::Open.call(stage:)
  end

  # An application on the job, written straight to the table: the knockout freeze reads only
  # "does any application exist" and the answer keys.
  def application_on!(job, answers: nil)
    answers ||= job.knockout_questions.to_h { |q| [q.id.to_s, "ya"] }
    JobApplication.create!(job:, knockout_answers: answers)
  end

  # --- house form rules (copied from test/engine/portal/portal_engine_support.rb) -------------
  def assert_engine_house_rules(html, where)
    doc = Nokogiri::HTML(html)
    doc.css("form").each { |form| assert_empty form.css("form"), "nested form on #{where}" }
    assert_empty doc.css("button[disabled], input[type=submit][disabled]"), "disabled submit on #{where}"
    assert_empty doc.css("[data-disable-with], [data-turbo-submits-with]"), "a button is disabled or relabelled on submit on #{where}"
    refute_match(/fa-eye\b/, html, "fa-eye on #{where} (house rule: fa-plus)")
    doc.css("form").each do |form|
      next if form["action"].to_s.end_with?("/session")

      form.css("button[type=submit], button:not([type]), input[type=submit]").each do |button|
        assert button["name"].present? && button["value"].present?,
               "a submit button without name/value on #{where}: #{button.to_html[0, 120]}"
      end
    end
    doc
  end

  # Serialises a rendered form the way a browser does when `button` is pressed, as an ordered
  # list of [name, value] pairs (repeated names such as brief[placements][] are kept). Readonly
  # fields ARE serialised (only disabled ones are not).
  def browser_pairs(form, button, fill = {})
    pairs = []
    form.css("input, textarea, select").each do |field|
      name = field["name"]
      next if name.blank? || field.key?("disabled")
      type = field["type"].to_s.downcase
      next if %w[submit button file].include?(type)
      next if %w[checkbox radio].include?(type) && !field.key?("checked")

      value = if field.name == "textarea" then field.text
              elsif field.name == "select" then field.css("option[selected]").first&.[]("value").to_s
              else field["value"].to_s
              end
      pairs << [name, value]
    end
    fill.each do |name, value|
      pairs.reject! { |n, _| n == name.to_s }
      pairs << [name.to_s, value]
    end
    pairs << [button["name"], button["value"]] if button && button["name"].present?
    pairs
  end

  # Presses the button on the current page through a real request; returns [response status,
  # params the controller received]. `fill` replaces fields by exact name.
  def press(button_value, fill = {}, button_name: nil)
    doc = Nokogiri::HTML(response.body)
    selector = button_name ? "form button[name='#{button_name}'][value='#{button_value}']" : "form button[value='#{button_value}']"
    button = doc.css(selector).first
    assert button, "no button '#{button_value}' on #{request.path}"
    form = button.ancestors("form").first
    pairs = browser_pairs(form, button, fill)
    method = (pairs.find { |n, _| n == "_method" }&.last || form["method"] || "get").downcase
    pairs.reject! { |n, _| n == "_method" }
    received = nil
    callback = ->(*, payload) { received = payload[:params] }
    ActiveSupport::Notifications.subscribed(callback, "process_action.action_controller") do
      send(method, form["action"], params: URI.encode_www_form(pairs),
                                   headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" })
    end
    [response.status, received]
  end
end
