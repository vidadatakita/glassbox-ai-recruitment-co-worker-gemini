module TestCases
  # AI co-worker for the uploaded case (slice D, Vida 17 Oct 2026): together with the case study text
  # (Briefs::Suggest step 5: instructions, time limit, rubric) the AI proposes the CASE FILE itself — a
  # data table the applicant works on, with a few planted errors tied to the brief's activities, and an
  # answer key for the reviewer. The model returns rows, never file bytes; Ruby builds the .xlsx
  # (workbook) with two sheets for the applicant (Instructions, Data). The answer key is NEVER put in the
  # applicant's file: it is shown to staff on the proposal and belongs in the rubric anchors.
  # Stored as a BriefSuggestion (payload "case_file"); nothing is saved until the HR Admin presses Save
  # on the step-5 form, which then goes through TestCases::SaveVersion and FileInspection like an
  # upload; approval is unchanged. Only the saved brief is sent (no applicant data). Tier MEDIUM.
  class DraftCaseFile
    Result = Data.define(:suggestion, :error) do
      def ok? = error.nil?
    end
    PROMPT_VERSION = "case-file-2026-10-17.1"
    MAX_ROWS = 40
    MAX_COLUMNS = 8

    SYSTEM = <<~PROMPT.freeze
      You build the data file for a short practical case for one job of an Indonesian employer. The
      applicant opens it in Excel and works on it within the time limit. A consultant reviews and edits
      everything before any applicant sees it. Write every text in English; invent every name, company
      and figure (no real people or companies).
      Return:
      - title: a short name for the data (e.g. "Purchase journal, October 2026").
      - columns: 3 to 8 column headings.
      - rows: 10 to 40 rows of values, one string per column, realistic for the work.
      - planted: 2 to 4 deliberate errors placed in the rows that someone doing the job well would find
        (a wrong total, a duplicate, a mismatch between two columns, a missing approval...). For each:
        row = the 1-based row NUMBER in rows, activity = the NUMBER of the job activity it tests,
        what = what is wrong, correct = the right value or action.
      Every planted error must be findable from the file alone. Never involve personal characteristics.
    PROMPT
    ROW = Briefs::Suggest::ROW
    SCHEMA = ROW.call(
      title: { type: "string" }, columns: { type: "array", items: { type: "string" } },
      rows: { type: "array", items: { type: "array", items: { type: "string" } } },
      planted: { type: "array", items: ROW.call(row: { type: "integer" }, activity: { type: "integer" }, what: { type: "string" }, correct: { type: "string" }) }
    ).freeze

    def self.call(job:, actor:, instructions: nil) = new(job:, actor:, instructions:).call

    def initialize(job:, actor:, instructions:)
      @job = job
      @actor = actor
      @instructions = instructions.to_s.strip[0, 3000].presence
      @activities = job.activities.to_a
    end

    def call
      return Result.new(nil, "AI drafting is off: no AI provider is configured.") unless Screening::Config.enabled?
      return Result.new(nil, "Save the activities in step 2 first; the case tests them.") if @activities.empty?

      reply = Screening::Config.client(:test_bank, job: @job).generate(system: SYSTEM, schema: SCHEMA, content:)
      data = normalise(JSON.parse(reply.text))
      return Result.new(nil, "The AI case file was not usable (#{data}). Try again.") if data.is_a?(String)

      suggestion = BriefSuggestion.create!(job: @job, actor: @actor, model_id: reply.model, prompt_version: PROMPT_VERSION,
                                           payload: { "case_file" => data }, input_tokens: reply.input_tokens,
                                           output_tokens: reply.output_tokens, created_at: Time.current)
      Result.new(suggestion, nil)
    rescue JSON::ParserError
      Result.new(nil, "The AI answer could not be read. Try again.")
    rescue Screening::Errors::Transient
      Result.new(nil, "The AI service is busy or unreachable. Try again in a moment.")
    rescue Screening::Errors::Base => e
      Result.new(nil, "The AI case file could not be drafted (#{e.detail}).")
    end

    # The applicant's .xlsx from a stored proposal: Instructions and Data only (no answer key).
    def self.workbook(case_file, instructions)
      package = Axlsx::Package.new
      book = package.workbook
      head = book.styles.add_style(b: true, bg_color: "1F3A5F", fg_color: "FFFFFF")
      wrap = book.styles.add_style(alignment: { wrap_text: true, vertical: :top })
      book.add_worksheet(name: "Instructions") do |sheet|
        sheet.add_row [case_file["title"]], style: head
        instructions.to_s.split(/\n+/).each { |line| sheet.add_row [line], style: wrap }
        sheet.column_widths 110
      end
      book.add_worksheet(name: "Data") do |sheet|
        sheet.add_row case_file["columns"], style: head
        case_file["rows"].each { |row| sheet.add_row row, types: [:string] * row.size }
        sheet.sheet_view.pane { |pane| pane.top_left_cell = "A2"; pane.state = :frozen; pane.y_split = 1 }
      end
      package.to_stream.read
    end

    private

    def content
      lines = ["Position: #{@job.title}", "Activities (numbered):"]
      lines.concat(@activities.each_with_index.map { |a, i| "#{i + 1}. #{a.description} (output: #{a.output})" })
      lines << "Case instructions the applicant will read:\n#{@instructions}" if @instructions
      lines.join("\n")
    end

    # Returns the cleaned proposal, or a String saying why it is unusable.
    def normalise(data)
      return "no data" unless data.is_a?(Hash)

      columns = Array(data["columns"]).map { |c| c.to_s.strip }.reject(&:empty?).first(MAX_COLUMNS)
      return "fewer than 3 columns" if columns.size < 3

      rows = Array(data["rows"]).first(MAX_ROWS).filter_map do |row|
        next unless row.is_a?(Array)

        Array.new(columns.size) { |i| row[i].to_s.strip }
      end
      return "fewer than 5 rows" if rows.size < 5

      texts = [data["title"], *columns, *rows.flatten]
      return "a protected attribute was mentioned" if texts.any? { |t| t.to_s.match?(Briefs::Suggest::PROTECTED) }

      planted = Array(data["planted"]).filter_map do |p|
        next unless p.is_a?(Hash) && p["row"].to_i.between?(1, rows.size) && p["activity"].to_i.between?(1, @activities.size)

        { "row" => p["row"].to_i, "activity" => @activities[p["activity"].to_i - 1].description, "what" => p["what"].to_s.strip, "correct" => p["correct"].to_s.strip }
      end
      return "no planted error points at a real row and activity" if planted.empty?

      { "title" => data["title"].to_s.strip.presence || "Case data", "columns" => columns, "rows" => rows, "planted" => planted }
    end
  end
end
