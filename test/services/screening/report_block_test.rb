require "test_helper"

# Feature 08 (D61, D62 h2/h3; plan Part 2 §i): the optional "report" block of the S1 answer,
# prompt s1-2026-10-16.3. The Gemini API is stubbed at the HTTP boundary (FakeGemini), so the
# request asserted is the one the real gem built.
class Screening::ReportBlockTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ScreeningFactory

  setup do
    @job = screening_job
    @fake = FakeGemini.new
  end

  def report(**overrides)
    {
      last_position: { text: "Admin Gudang, PT Logistik Makmur", quote: "Admin Gudang di PT Logistik Makmur" },
      education: { text: "D3 Manajemen Logistik", quote: "D3 Manajemen Logistik" },
      recent_experience: { text: "Mengelola stok gudang.", quote: "Mengelola stok 1.200 SKU" },
      strengths: [{ claim: "Terbiasa dengan stok besar", quote: "Mengelola stok 1.200 SKU" }],
      blind_spots: [{ claim: "Belum terlihat memimpin tim", quote: "kutipan yang tidak ada di CV" }],
      tolerance_risks: [],
      credibility_value: [{ claim: "Excel kuat", quote: "Microsoft Excel tingkat lanjut" }],
      label_proposal: "pertimbangkan", label_reason: "Syarat wajib terpenuhi."
    }.merge(overrides)
  end

  def screen(report_block)
    text = JSON.generate({ criteria: criteria_for(@job), protected_attribute_seen: false,
                           protected_attribute_categories: [], report: report_block }.compact)
    with_ai(@fake) do
      @fake.push(gemini_message(nil, text:))
      @participation = apply_with_cv!(@job)
      screen_and_release! # D51: a named reviewer releases the held CV before the call
    end
    @participation.reload.screening_results.sole
  end

  test "the report block is stored with every quote checked; an invented quote is kept and marked" do
    result = screen(report)
    assert_equal "s1-2026-10-16.4", result.prompt_version
    assert_equal({ "text" => "Admin Gudang, PT Logistik Makmur", "quote" => "Admin Gudang di PT Logistik Makmur", "verified" => true },
                 result.last_position)
    assert result.education["verified"]
    assert result.narratives["strengths"].sole["verified"]
    refute result.narratives["blind_spots"].sole["verified"], "a quote not in the CV must be marked unverified"
    assert_equal [], result.narratives["tolerance_risks"]
    assert_equal "pertimbangkan", result.label_proposal
    assert_equal "Syarat wajib terpenuhi.", result.label_reason
    assert_empty result.protected_attribute_categories, "control: a well-formed block is trusted"
  end

  test "a reply WITHOUT the report block is screened and scored exactly as before" do
    result = screen(nil)
    assert_nil result.last_position
    assert_nil result.label_proposal
    assert_equal BigDecimal("100"), result.score, "the report never moves the S1 score"
    assert_empty result.protected_attribute_categories
  end

  test "the model can never propose Over-qualified: the block is a schema breach, nothing stored, reviewer" do
    result = screen(report(label_proposal: "over_qualified"))
    assert_nil result.label_proposal
    assert_nil result.narratives
    assert_includes result.protected_attribute_categories, "other"
  end

  test "an unknown key inside the report block is a schema breach (F-33 rule), its text never stored" do
    result = screen(report(usia_kandidat: "kandidat berusia muda"))
    assert_nil result.last_position
    refute_includes result.attributes.to_json, "berusia muda"
    assert_includes result.protected_attribute_categories, "other"
  end

  test "the schema carries the report block as optional, closed, with five AI labels" do
    screen(report)
    schema = @fake.parsed_bodies.first.dig("generationConfig", "responseJsonSchema")
    refute_includes schema["required"], "report", "optional: an old-shape answer must stay valid"
    block = schema.dig("properties", "report")
    assert_equal false, block["additionalProperties"]
    assert_equal Screening::ReportFields::KEYS.sort, block["required"].sort
    assert_equal %w[direkomendasikan pertimbangkan pertimbangkan_terbatas tidak_prioritas tidak_relevan],
                 block.dig("properties", "label_proposal", "enum")
    refute_includes JSON.generate(block), "over_qualified"
    assert_includes @fake.parsed_bodies.first.dig("systemInstruction", "parts", 0, "text").to_s, "age or length of career as a stand-in for age"
  end
end
