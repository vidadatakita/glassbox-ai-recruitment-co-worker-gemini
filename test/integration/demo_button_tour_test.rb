require "test_helper"

# "Every button works" (demo preparation, 17 Oct 2026). Seeds the demo exactly as Demo::Reset does,
# then, signed in as each demo account, walks every staff page reachable from the vacancy list:
# every internal link is opened, and every form on every page is submitted once per submit button
# with the values the page itself fills in. Each submit runs in a savepoint that is rolled back, so one
# button never changes what the next page shows. A press may be refused (redirect with a message, or
# 422 with the errors shown); it may never raise, answer 5xx, or point at a route that does not exist.
class DemoButtonTourTest < ActionDispatch::IntegrationTest
  ACCOUNTS = %w[hr@terangnusantara.example manager@terangnusantara.example admin@glassbox.example].freeze
  # Paths the tour does not follow: signing out ends the walk; the demo door and reset belong to the
  # public entry, not the staff screens.
  SKIP = [%r{\A/session\z}, %r{\A/demo}, %r{\A/rails/}, %r{\A/up\z}].freeze
  MAX_PAGES = 400

  setup do
    @saved = %i[enabled? review_before_ai?].to_h { |name| [name, Screening::Config.method(name)] }
    with_env("DEMO_MODE" => "1", "LEGACY_DEMO_SEEDS" => nil) { capture_io { Rails.application.load_seed } }
  end
  teardown { @saved.each { |name, original| Screening::Config.singleton_class.define_method(name, original) } }

  test "every link and every button on every reachable staff page works for every demo account" do
    problems = []
    ACCOUNTS.each do |email|
      user = User.find_by!(email_address: email)
      sign_in_as user
      found, pages, presses = walk(user)
      puts "#{user.role}: #{pages} pages opened, #{presses} buttons pressed"
      # A walk that reached almost nothing proves nothing (a check that cannot fail).
      assert_operator pages, :>=, 40, "#{user.role} reached only #{pages} pages"
      assert_operator presses, :>=, 15, "#{user.role} pressed only #{presses} buttons"
      problems.concat(found)
      sign_out
    end
    assert_empty problems, "#{problems.size} broken links or buttons:\n#{problems.uniq.first(60).join("\n")}"
  end

  test "control: the tour reports a link that answers 404 and a form whose route does not exist" do
    sign_in_as User.find_by!(email_address: ACCOUNTS.first)
    assert_equal 404, fetch(:get, "/staff/jobs/#{Job.maximum(:id).to_i + 999}").first
    assert_equal 404, fetch(:post, "/staff/no-such-button").first, "an unknown route answers 404 in tests (rescued), never 2xx"
  end

  private

  def walk(user)
    who = "#{user.role}"
    queue = [staff_jobs_path]
    seen = {}
    pressed = {}
    problems = []
    while (path = queue.shift) && seen.size < MAX_PAGES
      next if seen[path] || SKIP.any? { |re| re.match?(path) }

      seen[path] = true
      status, body = fetch(:get, path)
      if status.is_a?(String) || status >= 500 || status == 404
        problems << "#{who} GET #{path}: #{status}"
        next
      end
      next unless status == 200 && body.to_s.include?("<html")

      doc = Nokogiri::HTML(body)
      doc.css("a[href]").each do |a|
        href = internal(a["href"])
        queue << href if href && !seen[href] && !a["href"].start_with?("#")
      end
      doc.css("form").each do |form|
        action = internal(form["action"].presence || path)
        next unless action && !SKIP.any? { |re| re.match?(action) }

        submits = form.css("button[type=submit], button:not([type]), input[type=submit]")
        submits = [nil] if submits.empty?
        submits.each do |button|
          key = [form["method"], action, button&.[]("name"), button&.[]("value")]
          next if pressed[key]

          pressed[key] = true
          verb = (form.at_css("input[name=_method]")&.[]("value") || form["method"] || "get").downcase.to_sym
          params = form_params(form, button)
          code, = in_savepoint { fetch(verb, action, params) }
          label = button&.text.to_s.squish.presence || button&.[]("value") || "submit"
          problems << "#{who} #{verb.upcase} #{action} [#{label}] on #{path}: #{code}" if code.is_a?(String) || code >= 500 || code == 404
        end
      end
    end
    [problems, seen.size, pressed.size]
  end

  # Returns [status, body]; a raised exception comes back as its class and message instead of a status.
  def fetch(verb, path, params = {})
    send(verb, path, params:)
    [response.status, response.body]
  rescue ActionController::RoutingError, AbstractController::ActionNotFound => e
    ["routing error #{e.message[0, 120]}", nil]
  rescue StandardError => e
    ["#{e.class}: #{e.message[0, 160]}", nil]
  end

  def in_savepoint
    result = nil
    ActiveRecord::Base.transaction(requires_new: true) do
      result = yield
      raise ActiveRecord::Rollback
    end
    result
  end

  # The values the page fills in, as the browser would send them, plus the pressed button.
  def form_params(form, button)
    pairs = []
    form.css("input[name], textarea[name], select[name]").each do |field|
      next if field["disabled"]

      name = field["name"]
      case field.name
      when "textarea" then pairs << [name, field.text]
      when "select"
        option = field.at_css("option[selected]") || field.at_css("option")
        pairs << [name, option ? (option["value"] || option.text) : ""]
      else
        type = (field["type"] || "text").downcase
        next if %w[submit button image file reset].include?(type)
        next if %w[checkbox radio].include?(type) && !field["checked"]

        pairs << [name, field["value"].to_s]
      end
    end
    pairs << [button["name"], button["value"].to_s] if button && button["name"].present?
    Rack::Utils.parse_nested_query(pairs.map { |k, v| "#{Rack::Utils.escape(k)}=#{Rack::Utils.escape(v)}" }.join("&"))
  end

  def internal(href)
    return if href.blank? || href.start_with?("mailto:", "tel:", "javascript:", "#")

    uri = URI.parse(href)
    return if uri.host && uri.host != "www.example.com"

    uri.path.presence && [uri.path, uri.query].compact.join("?")
  rescue URI::InvalidURIError
    nil
  end
end
