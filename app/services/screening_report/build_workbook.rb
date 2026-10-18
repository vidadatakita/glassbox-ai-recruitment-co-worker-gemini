module ScreeningReport
  # "Screening report" as an xlsx (D61, D62 h8; excel-export-standard): the same columns
  # as the screen, in the same order and sort, for the same viewer. Visibility is the board's:
  #   - names only when ScreeningReport::Visibility#names? (a blind client export before the gate
  #     decisions are confirmed shows "Candidate 07"),
  #   - the Email and WhatsApp number columns only when #contacts? (HR PIC after confirmation, the
  #     consultant); for everyone else the columns do not exist at all, not blank.
  # Every text cell goes through CellEscape. The one derived figure, the 1-5 band, ships as a live
  # formula over the 0-100 cell of its own row with the system's value cached (excel-export-standard
  # §3), so the sheet proves the band rule itself. The CONFIDENTIAL footer carries the generation
  # time, the AI model(s) and prompt version(s) behind the figures (blueprint §4.1 rule 9).
  class BuildWorkbook
    # [header, extractor(row, board) -> value, kind]. kind: :text (escaped), :number, :band.
    COLUMNS = [
      ["No", ->(_row, _board, i) { i + 1 }, :number],
      ["Name", ->(row, board, _i) { board.visibility.name_for?(row.application) ? row.candidate&.name.to_s : row.person_number }, :text],
      ["Last position", ->(row, board, _i) { board.ai_text(row, Text.last_position(row.result)) }, :text], # masked for blind viewers (engine 08 F-01)
      # An unjudged calibration CV is blank for the people who judge calibration (row.blinded).
      ["AI score (S1) 0–100", ->(row, _b, _i) { row.ai_score&.to_f }, :number],
      ["AI score (S1) 1–5", ->(row, _b, _i) { row.band }, :band],
      ["Technical test score (S2)", ->(row, _b, _i) { row.test.state == :scored ? row.test.score.to_f : row.test.label }, :mixed],
      ["CV screening result", ->(row, _b, _i) { GateCell.word(row.gate) }, :text],
      ["Expected salary", ->(row, _b, _i) { Text.salary_short(row.application.expected_salary_min, row.application.expected_salary_max) }, :text],
      ["FIT: Budget", ->(row, _b, _i) { Budget.label(row.budget) }, :text],
      ["Label", ->(row, _b, _i) { Text.label(row) }, :text],
      ["Interview appointment", ->(row, _b, _i) { Text.appointment(row.appointment) }, :text],
      ["Hiring manager's pick", ->(row, _b, _i) { Text.recommendation(row.recommendation) }, :text]
    ].freeze
    CONTACT_COLUMNS = [
      ["Email", ->(row, _b, _i) { row.candidate&.email.to_s }, :text],
      ["WhatsApp number", ->(row, _b, _i) { row.candidate&.phone.to_s }, :text],
      # D54: the city follows the contact rule (never in a blind export).
      ["City of residence", ->(row, _b, _i) { row.application.domicile_city.presence || "—" }, :text]
    ].freeze
    SCORE_COLUMN = 3 # 0-based index of "AI score (S1) 0-100"; the band formula reads it
    FIRST_DATA_ROW = 5 # 1-based: title, subtitle, rule, blank-free header at 4, data from 5
    WIDTHS = [6, 22, 30, 12, 10, 16, 18, 22, 22, 32, 30, 28, 30, 18, 18].freeze

    def self.call(board) = new(board).call

    def initialize(board)
      @board = board
      @columns = board.visibility.contacts? ? COLUMNS + CONTACT_COLUMNS : COLUMNS
    end

    # Returns an Axlsx::Package; the controller streams package.to_stream.read.
    def call
      package = Axlsx::Package.new
      package.use_shared_strings = true
      book = package.workbook
      styles = ZynixWorkbookTheme.styles(book)
      book.add_worksheet(name: "Screening Report") { |sheet| fill(sheet, styles) }
      book.add_worksheet(name: "Criteria Scoring") { |sheet| fill_criteria(sheet, styles) }
      package
    end

    def columns = @columns

    private

    def fill(sheet, styles)
      width = @columns.size
      ZynixWorkbookTheme.band(sheet, CellEscape.call("Screening report · #{@board.job.title}"), styles[:title], width)
      ZynixWorkbookTheme.band(sheet, CellEscape.call(subtitle), styles[:subtitle], width)
      ZynixWorkbookTheme.band(sheet, "", styles[:rule], width)
      sheet.add_row(@columns.map(&:first), style: Array.new(width, styles[:header]), types: Array.new(width, :string))
      @board.rows.each_with_index { |row, i| add_data_row(sheet, row, i, styles) }
      ZynixWorkbookTheme.band(sheet, CellEscape.call(Band::RULE), styles[:footer], width)
      ZynixWorkbookTheme.band(sheet, CellEscape.call(footer), styles[:footer], width)
      sheet.sheet_view.pane { |pane| freeze(pane) }
      sheet.column_widths(*WIDTHS.first(width))
    end

    # D53: one row per candidate per criterion, the 1-5 shown (CriterionScale) beside the AI's
    # original judgement; same order and same name rule as the first sheet; every text escaped.
    CRITERIA_HEADERS = ["No", "Name", "Requirement", "Tier", "Score (1–5)", "AI advice", "CV quote"].freeze

    def fill_criteria(sheet, styles)
      width = CRITERIA_HEADERS.size
      ZynixWorkbookTheme.band(sheet, CellEscape.call("Criteria scoring · #{@board.job.title}"), styles[:title], width)
      ZynixWorkbookTheme.band(sheet, "", styles[:rule], width)
      sheet.add_row(CRITERIA_HEADERS, style: Array.new(width, styles[:header]), types: Array.new(width, :string))
      @board.rows.each_with_index do |row, i|
        name = @board.visibility.name_for?(row.application) ? row.candidate&.name.to_s : row.person_number
        row.result&.criteria.to_a.each do |c|
          values = [i + 1, CellEscape.call(name), CellEscape.call(c["text"]), CellEscape.call(Requirement::TIERS.fetch(c["tier"], c["tier"])),
                    CriterionScale.of(c["tier"], c["judgement"]), CellEscape.call(Text.judgement(c["tier"], c["judgement"])),
                    CellEscape.call(@board.ai_text(row, c["quote"].to_s))]
          sheet.add_row(values, types: %i[integer string string string integer string string],
                                style: Array.new(width, i.odd? ? styles[:zebra] : styles[:body]))
        end
      end
      ZynixWorkbookTheme.band(sheet, CellEscape.call(CriterionScale::RULE), styles[:footer], width)
      ZynixWorkbookTheme.band(sheet, CellEscape.call(footer), styles[:footer], width)
      sheet.sheet_view.pane { |pane| pane.top_left_cell = "A4"; pane.state = :frozen; pane.y_split = 3 }
      sheet.column_widths(6, 22, 40, 14, 10, 16, 50)
    end

    def add_data_row(sheet, row, index, styles)
      base = index.odd? ? styles[:zebra] : styles[:body]
      excel_row = FIRST_DATA_ROW + index
      values = []
      types = []
      cell_styles = []
      @columns.each_with_index do |(header, extract, kind), col|
        value, type = cell(extract.call(row, @board, index), kind, excel_row)
        values << value
        types << type
        cell_styles << (header == "Label" ? label_style(row, styles, base) : base)
      end
      added = sheet.add_row(values, types:, style: cell_styles)
      band_cell = added.cells[SCORE_COLUMN + 1]
      band_cell.escape_formulas = false
      band_cell.formula_value = row.band if row.band
    end

    def cell(value, kind, excel_row)
      case kind
      when :number then value.nil? ? [nil, :string] : [value, value.is_a?(Integer) ? :integer : :float]
      when :band then [band_formula(excel_row), :string]
      when :mixed then value.is_a?(Numeric) ? [value, :float] : [CellEscape.call(value), :string]
      else [CellEscape.call(value), :string]
      end
    end

    # 0-19.9 = 1 ... 80-100 = 5 (D62 h1), as Excel computes it from the 0-100 cell of this row.
    def band_formula(excel_row)
      ref = "#{column_letter(SCORE_COLUMN)}#{excel_row}"
      "=IF(#{ref}=\"\",\"\",MIN(5,INT(#{ref}/20)+1))"
    end

    def column_letter(index) = ("A".ord + index).chr

    def label_style(row, styles, base)
      return base if row.label_key.nil?

      { "success" => styles[:success], "warning" => styles[:warning], "danger" => styles[:danger] }.fetch(Labels.tone(row.label_key), base)
    end

    def freeze(pane)
      pane.top_left_cell = "A#{FIRST_DATA_ROW}"
      pane.state = :frozen
      pane.y_split = FIRST_DATA_ROW - 1
    end

    def subtitle
      view = @board.visibility.names? ? "names shown" : "names masked until the gate decision is confirmed"
      "Order: CV screening result, then AI score, technical test score, application time. #{@board.rows.size} applicants; #{view}."
    end

    def footer
      stamp = I18n.l(@board.now.in_time_zone("Asia/Jakarta"), format: "%-d %b %Y %H.%M")
      # Model and prompt version stay in the records (blueprint §4.1 rule 9), not in the file (owner, 2026-10-11).
      "CONFIDENTIAL · for the recruitment of #{@board.job.title} · generated #{stamp} WIB"
    end
  end
end
