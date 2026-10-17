require "test_helper"

# Brief progress on the brief page (Vida, 17 Oct 2026): every step is clickable, to its section on the
# page (each target id exists) or to the technical-test step's own page.
class BriefProgressLinksTest < ActionDispatch::IntegrationTest
  test "every brief step links to a section that exists, step 5 to its page" do
    job = briefed_job(golongan: 3, package: 3, complete: true, test_case: true)
    sign_in_as staff_user("hr_pic")
    get staff_job_brief_path(job)
    assert_response :success
    doc = Nokogiri::HTML(response.body)
    links = doc.css("#brief-progress a.hiring-progress__link")
    assert_equal BriefProgress.new(job).steps.size, links.size, "every step is a link"
    links.each do |a|
      href = a["href"]
      if href.start_with?("#")
        assert doc.at_css(href), "#{a.text.squish} points at #{href}, which is on the page"
      else
        assert_equal staff_job_test_case_step_path(job), href
      end
    end
    assert_equal response.body.scan(/<form\b/).size, doc.css("form").size, "no form inside a form"
  end
end
