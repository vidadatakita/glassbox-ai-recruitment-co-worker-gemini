require "net/http"

module TechnicalTests
  # The text of one technical-test answer, for the AI to score (TechnicalTests::AiScore) and for the
  # reviewer to read BEFORE anything is sent (the preview is the release step, as for CVs).
  #
  # Files: csv as written; pdf via pdf-reader; docx and xlsx from their XML parts (rubyzip,
  # nokogiri), cells as "Sheet!A1: value" lines. The candidate's name, email and phone are redacted
  # (Screening::Redactor), because a document often carries them.
  #
  # Repository links: GitHub only, through the GitHub API on its own fixed host (api.github.com,
  # raw.githubusercontent.com). The candidate's URL only supplies owner and repo, both matched to
  # [A-Za-z0-9_.-]+, so no request ever goes to a host the candidate chose (no SSRF). Only on the
  # reviewer's request, only text files, capped in count and size. It reads the repository AS IT IS
  # NOW, which may be after the deadline: the preview says so.
  class AnswerText
    Result = Data.define(:text, :problem, :source) do
      def ok? = problem.nil?
    end

    MAX_CHARS = 60_000
    MAX_FILES = 25
    MAX_FILE_BYTES = 40_000
    CODE = /\.(rb|py|js|jsx|ts|tsx|java|kt|go|php|cs|c|cc|cpp|h|rs|swift|scala|sql|html|css|scss|vue|svelte|sh|ya?ml|json|toml|md|txt|env\.example|gradle|xml|ex|exs|dart)\z/i
    SKIP = %r{(\A|/)(node_modules|vendor|dist|build|\.git|\.next|coverage|tmp|log)/|(\A|/)[^/]*(lock|\.min\.js|\.map)\z}i
    GITHUB = %r{\Ahttps://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?(?:/.*)?\z}

    def self.call(attempt) = new(attempt).call

    def initialize(attempt)
      @attempt = attempt
    end

    def call
      return Result.new(nil, "No answer yet.", nil) unless @attempt.answered?
      return repository if @attempt.repo_link?

      text = from_file
      return Result.new(nil, "The answer file content cannot be read as text.", nil) if text.to_s.strip.empty?

      name = @attempt.participation.job_application.candidate&.name
      Result.new(Screening::Redactor.call(text, names: [name].compact).text[0, MAX_CHARS], nil, "file #{@attempt.answer_kind}")
    end

    private

    def from_file
      bytes = @attempt.answer_file.download
      case @attempt.answer_kind
      when "csv" then bytes.force_encoding("UTF-8").scrub
      when "pdf" then pdf(bytes)
      when "docx" then docx(bytes)
      when "xlsx" then xlsx(bytes)
      end
    end

    def pdf(bytes)
      require "pdf-reader"
      PDF::Reader.new(StringIO.new(bytes)).pages.map(&:text).join("\n")
    rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError, PDF::Reader::EncryptedPDFError
      nil
    end

    def zip_entries(bytes)
      require "zip"
      Zip::File.open_buffer(bytes) { |zip| return zip.entries.to_h { |e| [e.name, e.get_input_stream.read] } }
    end

    def docx(bytes) = Screening::CvText.docx(bytes)

    def xlsx(bytes)
      parts = zip_entries(bytes)
      shared = Nokogiri::XML(parts["xl/sharedStrings.xml"].to_s).tap(&:remove_namespaces!).xpath("//si").map { |si| si.xpath(".//t").map(&:text).join }
      parts.keys.grep(%r{\Axl/worksheets/sheet\d+\.xml\z}).sort.flat_map do |name|
        sheet = File.basename(name, ".xml")
        Nokogiri::XML(parts[name]).tap(&:remove_namespaces!).xpath("//c").filter_map do |c|
          value = c.at_xpath("v|is/t")&.text
          next if value.nil?

          value = shared[value.to_i] if c["t"] == "s"
          "#{sheet}!#{c['r']}: #{value}"
        end
      end.join("\n")
    end

    def repository
      match = @attempt.answer_url.to_s.match(GITHUB)
      return Result.new(nil, "The AI can only read GitHub repositories. This repository is scored by hand.", nil) unless match

      owner, repo = match.captures
      meta = github_json("/repos/#{owner}/#{repo}")
      branch = meta.fetch("default_branch")
      tree = github_json("/repos/#{owner}/#{repo}/git/trees/#{ERB::Util.url_encode(branch)}?recursive=1").fetch("tree")
      files = tree.select { |f| f["type"] == "blob" && f["path"].match?(CODE) && !f["path"].match?(SKIP) && f["size"].to_i <= MAX_FILE_BYTES }
                  .first(MAX_FILES)
      return Result.new(nil, "The repository contains no readable code files.", nil) if files.empty?

      text = +""
      files.each do |f|
        break if text.size >= MAX_CHARS

        path = f["path"].split("/").map { |part| ERB::Util.url_encode(part) }.join("/")
        body = get("raw.githubusercontent.com", "/#{owner}/#{repo}/#{ERB::Util.url_encode(branch)}/#{path}")
        text << "=== #{f['path']} ===\n#{body.force_encoding('UTF-8').scrub}\n\n"
      end
      Result.new(text[0, MAX_CHARS], nil, "github.com/#{owner}/#{repo} (branch #{branch}, #{files.size} #{'file'.pluralize(files.size)})")
    rescue KeyError, JSON::ParserError, Fetch => e
      Result.new(nil, "The repository could not be read: #{e.message}. Make sure the repository is public, or score by hand.", nil)
    end

    class Fetch < StandardError; end

    def github_json(path) = JSON.parse(get("api.github.com", path))

    # Fixed hosts only; https; short timeouts; no redirects followed.
    def get(host, path)
      response = Net::HTTP.start(host, 443, use_ssl: true, open_timeout: 10, read_timeout: 20) do |http|
        http.get(path, "User-Agent" => "GlassBox", "Accept" => "application/vnd.github+json")
      end
      raise Fetch, "HTTP #{response.code}" unless response.code == "200"

      response.body
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError
      raise Fetch, "connection failed"
    end
  end
end
