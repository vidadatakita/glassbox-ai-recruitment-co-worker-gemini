require "test_helper"

# AI Builder Cup step 02: the job ad. Written (or proposed by the AI from the saved brief), checked
# for discriminatory wording on every save, recorded, and approved by HR with the flags in view.
class Briefs::AdTest < ActiveSupport::TestCase
  include PortalFactory
  include BriefFactory

  FakeClient = Struct.new(:text, :seen, :systems) do
    def generate(system:, schema:, content:)
      (self.seen ||= []) << content
      (self.systems ||= []) << system
      Screening::AiClient::Reply.new(model: "uji-model", text:, input_tokens: 1, output_tokens: 1)
    end
  end

  setup do
    @job = briefed_job(complete: true, ad: false) # these tests write the ad themselves
    @job.update_columns(ad_approved_at: nil, ad_approved_by_id: nil)
    @hr = staff_user("hr_pic")
  end

  test "the rules flag protected attributes and leave ordinary job words alone" do
    flags = Briefs::AdCheck.rule_flags("- Pria, usia maksimal 30 tahun\n- Berpenampilan menarik\n- Single Page Application\n- Mengelola suku cadang\n- Belum menikah")
    assert_equal ["- Pria, usia maksimal 30 tahun", "- Berpenampilan menarik", "- Belum menikah"], flags.map { |f| f["quote"] }
    assert flags.all? { |f| f["source"] == "rule" && f["reason"].present? }
  end

  # 16 Oct 2026: English patterns in the same rule table (the demo ad is English). Mutant: drop the
  # English alternatives from the gender row -> the first assertion goes red.
  test "the rules flag English protected attributes and leave English job words alone" do
    assert_equal "Gender may not be a requirement when anyone can do the work.", Briefs::AdCheck.rule_flags("- Male candidates only").sole["reason"]
    text = "- Male, maximum age 30\n- Attractive appearance\n- Able to lift 25 kg\n- Single Page Application\n- Christian only\n- Not married, no children\n- Minimum height 160 cm\n- Manager of a young company\n- Race condition debugging\n- Fluent English"
    flags = Briefs::AdCheck.rule_flags(text)
    assert_equal ["- Male, maximum age 30", "- Attractive appearance", "- Christian only", "- Not married, no children", "- Minimum height 160 cm", "- Manager of a young company"],
                 flags.map { |f| f["quote"] }
    # Every row a line trips is reported, in rule-table order: "Male, maximum age 30" names age AND gender.
    assert_equal [%w[age gender], %w[appearance], %w[religion], ["marital status"], ["body size"], %w[age]], flags.map { |f| f["categories"] }
    assert_equal ["An age limit may not be a requirement unless the law requires it. Gender may not be a requirement when anyone can do the work.",
                  "Physical appearance is not a work ability.", "Religion may not be a requirement.",
                  "Marital status or pregnancy may not be a requirement.", "Body size may only be asked for when the work truly needs it; write the reason.",
                  "An age limit may not be a requirement unless the law requires it."], flags.map { |f| f["reason"] }
  end

  # 16 Oct end-to-end test: this line got the age reason only, and the ad was approved and shown.
  # Mutant: back to the first matching row per line -> red.
  test "a line that names four protected attributes is one flag that names all four" do
    flag = Briefs::AdCheck.rule_flags("- Female, max 28, attractive, unmarried").sole
    assert_equal ["age", "gender", "appearance", "marital status"], flag["categories"]
    assert_equal "The job ad names a protected attribute (age, gender, appearance, marital status).", Briefs::AdCheck.rule_summary([flag])
    assert Briefs::AdCheck.rule_hit?([flag])
    refute Briefs::AdCheck.rule_hit?([{ "quote" => "fresh graduate", "reason" => "x", "source" => "ai" }]), "an AI flag needs the tick only"
    assert_equal "The job ad names a protected attribute.", Briefs::AdCheck.rule_summary([{ "quote" => "- Pria", "reason" => "x", "source" => "rule" }]),
                 "a flag stored before the categories existed"
  end

  test "a live ad's save that names a protected attribute needs HR's written reason, recorded with the change" do
    @job.update_columns(ad_approved_at: 2.days.ago, ad_approved_by_id: @hr.id, ad_text: "Tentang posisi ini\nTeks.")
    text = "Tentang posisi ini\n- Female, max 28, attractive, unmarried"
    Screening::Config.stub(:enabled?, false) do
      refused = Briefs::SaveAd.call(job: @job, actor: @hr, text:, confirmed: true)
      refute refused.ok?
      assert refused.needs_reason
      assert_includes refused.error, "(age, gender, appearance, marital status)"
      assert_equal ["- Female, max 28, attractive, unmarried"], refused.flags.map { |f| f["quote"] }
      assert_equal "Tentang posisi ini\nTeks.", @job.reload.ad_text, "nothing saved, nothing shown"
      assert Briefs::SaveAd.call(job: @job, actor: @hr, text:, confirmed: true, reason: "  Uji:   alasan tertulis. ").ok?
    end
    assert_equal text, @job.reload.ad_text
    change = @job.brief_changes.where(step: "ad").last
    assert_equal ["age, gender, appearance, marital status", "Uji: alasan tertulis."], change.changes_made["ad_flags_reason"]
  end

  test "an AI flag is kept only when its quote is really in the ad, and never repeats a rule flag" do
    text = "- Usia maksimal 30\n- Cocok untuk fresh graduate yang belum berkeluarga"
    answer = { "flags" => [{ "quote" => "fresh graduate yang belum berkeluarga", "reason" => "Status keluarga." },
                           { "quote" => "kalimat yang tidak ada", "reason" => "x" },
                           { "quote" => "Usia maksimal 30", "reason" => "dobel" }] }
    flags = Screening::Config.stub(:enabled?, true) do
      Screening::Config.stub(:client, FakeClient.new(answer.to_json)) { Briefs::AdCheck.call(text) }
    end
    assert_equal [["rule", "- Usia maksimal 30"], ["ai", "fresh graduate yang belum berkeluarga"]], flags.map { |f| [f["source"], f["quote"]] }
  end

  test "saving records the change and the flags"  do
    result = Screening::Config.stub(:enabled?, false) { Briefs::SaveAd.call(job: @job, actor: @hr, text: "Tentang posisi ini\n- Wanita, maksimal 25 tahun") }
    assert result.ok?
    assert_equal 1, @job.reload.ad_flags.size
    change = @job.brief_changes.where(step: "ad").last
    assert_equal [nil, "Tentang posisi ini\n- Wanita, maksimal 25 tahun"], change.changes_made["ad_text"]

  end

  test "an approved ad (even one approved before it had a text): HR alone edits it, each save with the tick re-approves it" do
    @job.update!(ad_approved_at: 2.days.ago, ad_approved_by_id: staff_user("owner").id)
    assert @job.legacy_ad?
    Screening::Config.stub(:enabled?, false) do
      refute Briefs::SaveAd.call(job: @job, actor: staff_user("consultant"), text: "Teks", confirmed: true).ok?, "only HR"
      refute Briefs::SaveAd.call(job: @job, actor: @hr, text: "Teks").ok?, "the tick is required"
      assert Briefs::SaveAd.call(job: @job, actor: @hr, text: "Tentang posisi ini\nTeks.", confirmed: true).ok?
    end
    @job.reload
    assert_equal @hr.id, @job.ad_approved_by_id, "the save is HR's approval of the text"
    refute @job.legacy_ad?
    refute Briefs::SaveAd.call(job: @job, actor: staff_user("consultant"), text: "lain", confirmed: true).ok?, "the consultant edits only before approval"
    refute Briefs::SaveAd.call(job: @job, actor: @hr, text: "lain").ok?, "a live ad changes only with the tick"
    Screening::Config.stub(:enabled?, false) { assert Briefs::SaveAd.call(job: @job, actor: @hr, text: "Teks baru", confirmed: true).ok? }
    assert_equal "Teks baru", @job.reload.ad_text
  end

  test "an optional instruction and the current draft go to the AI; the rules stay above them" do
    client = FakeClient.new({ ad_text: "Versi santai." }.to_json)
    result = Screening::Config.stub(:enabled?, true) do
      Screening::Config.stub(:client, client) do
        Briefs::Suggest.call(job: @job, actor: @hr, step: "ad", instruction: "Gaya santai untuk anak muda", draft: "Iklan lama saya.")
      end
    end
    sent = client.seen.first
    assert_includes sent, "Iklan lama saya."
    assert_includes sent, "Rewrite it fully in the requested style"
    system = client.systems.first
    assert_includes system, "THE RECRUITER'S REQUEST (first priority", "the wish is in the system prompt, where a model follows it"
    assert_includes system, "Gaya santai untuk anak muda"
    assert system.index("Never write the company name") < system.index("THE RECRUITER'S REQUEST"), "the never-rules come first"
    assert_equal "Gaya santai untuk anak muda", result.suggestion.payload["instruction"], "the wish is kept with the proposal"
  end

  test "the AI writes the ad from the SAVED brief, without the company name or a hidden salary" do
    @job.update!(show_salary: false, salary_min: 5_000_000, salary_max: 6_000_000)
    client = FakeClient.new({ ad_text: "Tentang posisi ini\nTeks iklan." }.to_json)
    result = Screening::Config.stub(:enabled?, true) do
      Screening::Config.stub(:client, client) { Briefs::Suggest.call(job: @job, actor: @hr, step: "ad") }
    end
    assert_equal "Tentang posisi ini\nTeks iklan.", result.suggestion.ad_text
    sent = client.seen.first
    assert_includes sent, @job.activities.first.description
    refute_includes sent, @job.client_company.name
    refute_includes sent, "5.000.000", "a salary hidden from the ad is not sent"
  end
end
