require "test_helper"

# "Ask AI" lives in a chat window behind a button at the bottom right of every staff page, not
# in a menu; it talks JSON. Shown to every staff role (all of them see job data), and only with an
# AI provider.
class DataChatWidgetTest < ActionDispatch::IntegrationTest
  Fake = Struct.new(:answers) do
    def generate(system:, schema:, content:)
      Screening::AiClient::Reply.new(model: "uji", text: answers.shift.to_json, input_tokens: 1, output_tokens: 1)
    end
  end

  def on(&) = Screening::Config.stub(:enabled?, true, &)

  # Three-role model (17 Oct 2026): the old reviewer (excluded before) and the old owner (included)
  # merged into HR manager, and every one of the three roles sees job data, so no role is refused any
  # more. The remaining refusal is "no AI provider, no button"; every role is asserted on the allowed side.
  test "the button and window are on staff pages for every role, not in the menu; not without AI" do
    sign_in_as staff_user("hr_pic")
    on { get staff_jobs_path }
    doc = Nokogiri::HTML(response.body)
    assert doc.at_css("button.data-chat__fab[aria-controls='data-chat-panel']")
    assert_equal "Ask AI", doc.at_css(".data-chat__fab .data-chat__fab-text").text.strip
    assert doc.at_css("#data-chat-panel[hidden]")
    assert_nil doc.at_css(".side-menu__item[href='#{staff_data_chat_path}']"), "no menu entry"

    Screening::Config.stub(:enabled?, false) { get staff_jobs_path }
    assert_nil Nokogiri::HTML(response.body).at_css(".data-chat__fab")

    %w[reviewer owner superadmin].each do |role|
      sign_in_as staff_user(role)
      on { get staff_jobs_path }
      assert Nokogiri::HTML(response.body).at_css(".data-chat__fab"), "#{role} has no Ask AI button"
      sign_out
    end
    assert_equal %w[hr_admin hr_manager superadmin], DataChat::ROLES.sort, "every role, so no role is refused"
  end

  test "a question is answered as JSON, with the data and links; the history comes back" do
    job = portal_job
    sign_in_as staff_user("hr_pic")
    fake = Fake.new([{ tool: "corong_pelamar", job_id: job.id.to_s, candidate_number: "" }, { answer: "Belum ada pelamar." }])
    on { Screening::Config.stub(:client, fake) { post staff_data_chat_path, params: { question: "Berapa pelamar?" }, as: :json } }
    body = JSON.parse(response.body)
    assert_equal ["answered", "Belum ada pelamar."], body.values_at("status", "answer")
    assert_equal staff_job_path(job), body["links"].first["path"]

    get staff_data_chat_path, as: :json
    last = JSON.parse(response.body).last
    assert_equal "Berapa pelamar?", last["question"]
    assert_equal staff_job_path(job), last["links"].first["path"], "the history keeps its links after a reload"

    get staff_data_chat_path
    assert_redirected_to staff_jobs_path(anchor: "tanya-data"), "opened in the browser: the window, never raw JSON"
  end
end
