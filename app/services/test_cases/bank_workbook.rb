module TestCases
  # The competency bank as an Excel workbook, both ways (slice D, 17 Oct 2026: "upload = import from an
  # Excel template"). export writes the template (empty) or the bank (filled): sheet 1 "Questions" is
  # what import reads back, one question per row; sheet 2 "Instructions" says how to fill it; sheet 3
  # "Lists" holds the allowed values, used by the drop-downs. What export writes, import accepts
  # unchanged (round trip), so a downloaded bank can be edited in Excel and uploaded again.
  module BankWorkbook
    HEADERS = ["Section", "Type", "Tests (activity or competency)", "Question", "Option A", "Option B", "Option C", "Option D",
               "Option E", "Option F", "Correct option (A-F)", "Score 1 when the answer", "Score 3 when the answer",
               "Score 5 when the answer"].freeze
    SECTION_WORDS = { "technical" => "Technical", "role" => "Role" }.freeze
    KIND_WORDS = { "multiple_choice" => "Multiple choice", "written" => "Written" }.freeze
    LETTERS = %w[A B C D E F].freeze

    module_function

    # Returns xlsx bytes. questions: the bank's questions, or [] for the empty template.
    def export(job, questions = [])
      package = Axlsx::Package.new
      book = package.workbook
      head = book.styles.add_style(b: true, bg_color: "1F3A5F", fg_color: "FFFFFF", alignment: { wrap_text: true, vertical: :top })
      wrap = book.styles.add_style(alignment: { wrap_text: true, vertical: :top })
      book.add_worksheet(name: "Questions") do |sheet|
        sheet.add_row HEADERS, style: head
        questions.each { |q| sheet.add_row row_for(q), style: wrap, types: [:string] * HEADERS.size }
        sheet.column_widths 12, 16, 36, 60, 22, 22, 22, 22, 22, 22, 14, 30, 30, 30
        sheet.sheet_view.pane { |pane| pane.top_left_cell = "A2"; pane.state = :frozen; pane.y_split = 1 }
        last = 500
        sheet.add_data_validation("A2:A#{last}", type: :list, formula1: "Lists!$A$2:$A$3", showErrorMessage: true, errorTitle: "Section", error: "Choose Technical or Role.")
        sheet.add_data_validation("B2:B#{last}", type: :list, formula1: "Lists!$B$2:$B$3", showErrorMessage: true, errorTitle: "Type", error: "Choose Multiple choice or Written.")
        links = job.activities.size + job.competencies.size
        sheet.add_data_validation("C2:C#{last}", type: :list, formula1: "Lists!$C$2:$C$#{links + 1}", showErrorMessage: true, errorTitle: "Tests", error: "Choose an activity or a competency of the brief.")
        sheet.add_data_validation("K2:K#{last}", type: :list, formula1: "Lists!$D$2:$D$7", showErrorMessage: true, errorTitle: "Correct option", error: "Choose A to F.")
      end
      book.add_worksheet(name: "Instructions") do |sheet|
        instructions(job).each { |line| sheet.add_row [line], style: wrap }
        sheet.column_widths 110
      end
      book.add_worksheet(name: "Lists") do |sheet|
        sheet.add_row ["Section", "Type", "Tests", "Correct"], style: head
        link_texts = job.activities.map(&:description) + job.competencies.map(&:name)
        rows = [SECTION_WORDS.values, KIND_WORDS.values, link_texts, LETTERS].map(&:dup)
        rows.map(&:size).max.times { |i| sheet.add_row rows.map { |r| r[i] }, types: [:string] * 4 }
      end
      package.to_stream.read
    end

    def row_for(q)
      [SECTION_WORDS[q.section], KIND_WORDS[q.kind], q.link_text, q.prompt, *LETTERS.each_index.map { |i| q.options[i] },
       q.multiple_choice? ? LETTERS[q.correct_index] : nil, q.anchor_1, q.anchor_3, q.anchor_5]
    end

    def instructions(job)
      ["Competency test bank: #{job.title}",
       "One question per row on the sheet 'Questions'. The first row is the header; keep it.",
       "Section: Technical (tests an activity of the job) or Role (tests a competency).",
       "Tests: choose from the list; Technical rows take an activity, Role rows a competency (the exact text of the brief).",
       "Type: Multiple choice (fill 2 to 6 options and the letter of the correct one) or Written (leave the options empty; fill the three 'Score' columns).",
       "Never ask about age, gender, religion, ethnicity, marital status, appearance or health.",
       "Upload the file in brief step 5. Every row is checked; if one row is wrong, nothing is added and each problem is listed with its row number."]
    end

    # Reads sheet 1 into hashes keyed by header, with the Excel row number. Raises ArgumentError when the
    # file is not a readable workbook or the header row is not the template's.
    def read(bytes)
      parts = {}
      Zip::File.open_buffer(StringIO.new(bytes)) do |zip|
        zip.each do |entry|
          next unless entry.name.match?(%r{\Axl/(sharedStrings\.xml|workbook\.xml|_rels/workbook\.xml\.rels|worksheets/sheet\d+\.xml)\z}) && entry.size.to_i < 5_000_000

          parts[entry.name] = entry.get_input_stream.read
        end
      end
      sheet = parts[questions_part(parts)] or raise ArgumentError, "The file has no sheet 'Questions'."
      shared = Nokogiri::XML(parts["xl/sharedStrings.xml"].to_s).tap(&:remove_namespaces!).xpath("//si").map { |si| si.xpath(".//t").map(&:text).join }
      grid = {}
      Nokogiri::XML(sheet).tap(&:remove_namespaces!).xpath("//c").each do |c|
        col, row = c["r"].to_s.match(/\A([A-Z]+)(\d+)\z/)&.captures
        next unless col

        value = c["t"] == "inlineStr" ? c.at_xpath("is")&.xpath(".//t")&.map(&:text)&.join : c.at_xpath("v")&.text
        value = shared[value.to_i] if c["t"] == "s" && value
        (grid[row.to_i] ||= {})[col] = value.to_s.strip
      end
      header = (grid[1] || {}).sort_by { |col, _| col_index(col) }.map(&:last)
      raise ArgumentError, "The header row is not the template's. Download the template and keep its first row." unless header.first(HEADERS.size) == HEADERS

      grid.except(1).sort.filter_map do |row, cells|
        values = HEADERS.each_index.to_h { |i| [HEADERS[i], cells[col_letter(i)].to_s] }
        next if values.values.all?(&:empty?)

        values.merge("_row" => row)
      end
    rescue Zip::Error, Nokogiri::XML::SyntaxError
      raise ArgumentError, "The file is not a readable Excel workbook (.xlsx)."
    end

    # The sheet NAMED "Questions" (Excel lets the user reorder sheets; independent test pass, slice D,
    # F5), falling back to the first sheet for a workbook without that name.
    def questions_part(parts)
      book = Nokogiri::XML(parts["xl/workbook.xml"].to_s).tap(&:remove_namespaces!)
      rels = Nokogiri::XML(parts["xl/_rels/workbook.xml.rels"].to_s).tap(&:remove_namespaces!)
      rid = book.xpath("//sheet").find { |sheet| sheet["name"] == "Questions" }&.[]("id")
      # Compared in Ruby, never interpolated into XPath: the id comes from the uploaded file (independent
      # test pass, slice D, F8: a quote in it crashed the query).
      target = rid && rels.xpath("//Relationship").find { |rel| rel["Id"] == rid }&.[]("Target")
      target ? "xl/#{target.delete_prefix('/xl/').delete_prefix('/')}" : "xl/worksheets/sheet1.xml"
    end

    def col_letter(index) = ("A".ord + index).chr
    def col_index(letters) = letters.chars.reduce(0) { |n, ch| n * 26 + ch.ord - 64 }
  end
end
