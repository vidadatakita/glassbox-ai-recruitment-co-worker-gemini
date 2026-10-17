module TestCases
  # Imports questions from the bank workbook (TestCases::BankWorkbook) into the bank's editable version.
  # All or nothing: every row is turned into the same params the screen sends and saved through
  # TestCases::SaveBank inside ONE transaction; if any row is refused, nothing is added and every problem
  # is reported with its Excel row number, so the HR Admin fixes the file and uploads it again.
  # Imported questions are marked source "import". The file is checked first (FileInspection: an
  # .xlsx, no macros or embedded objects, 5 MB at most).
  class ImportBank
    Result = Data.define(:added, :errors) do
      def ok? = errors.empty?
    end
    MAX_BYTES = 5.megabytes
    MAX_ROWS = 300

    def self.call(**kwargs) = new(**kwargs).call

    # reason: the new-version reason, needed when the bank's newest version is approved (the import then
    # starts version n + 1 as a copy and adds the rows to it; independent test pass, slice D, F3).
    def initialize(job:, actor:, file:, reason: nil)
      @job = job
      @actor = actor
      @file = file
      @reason = reason.to_s.strip.presence
    end

    def call
      return Result.new(0, ["Choose the Excel file to upload."]) if @file.blank?
      return Result.new(0, [Authority.edit_refusal(@actor, @job)]) unless Authority.may_edit_bank?(@actor, @job)

      inspection = FileInspection.call(io: @file, filename: @file.original_filename.to_s, allowed: %w[xlsx], max_bytes: MAX_BYTES)
      @file.rewind
      return Result.new(0, inspection.problems) unless inspection.ok?

      rows = BankWorkbook.read(@file.read)
      return Result.new(0, ["The sheet 'Questions' has no question rows."]) if rows.empty?
      return Result.new(0, ["The file has #{rows.size} questions; upload at most #{MAX_ROWS} at a time."]) if rows.size > MAX_ROWS
      latest = QuestionBank.latest_for(@job)
      if latest&.approved? && @reason.nil?
        return Result.new(0, ["Version #{latest.version} is approved, so the import starts version #{latest.version + 1}: write the reason for the new version."])
      end

      errors = []
      ActiveRecord::Base.transaction do
        rows.each do |row|
          params = to_params(row, errors)
          next if params.nil?

          params = params.merge(new_version_reason: @reason) if @reason
          result = SaveBank.call(job: @job, actor: @actor, action: "add", params:, source: "import")
          errors.concat(result.errors.map { |e| "Row #{row['_row']}: #{e}" }) unless result.ok?
        end
        raise ActiveRecord::Rollback if errors.any?
      end
      errors.any? ? Result.new(0, errors) : Result.new(rows.size, [])
    rescue ArgumentError => e
      Result.new(0, [e.message])
    end

    private

    def to_params(row, errors)
      at = "Row #{row['_row']}"
      section = BankWorkbook::SECTION_WORDS.key(row["Section"]) || row["Section"].downcase.presence
      kind = BankWorkbook::KIND_WORDS.key(row["Type"]) || row["Type"].downcase.tr(" ", "_").presence
      link = link_id(section, row["Tests (activity or competency)"])
      if link.nil?
        errors << "#{at}: \"#{row['Tests (activity or competency)']}\" is not #{section == 'role' ? 'a competency' : 'an activity'} of this vacancy's brief; choose it from the list."
        return
      end
      params = { section:, kind:, link_id: link, prompt: row["Question"], anchor_1: row["Score 1 when the answer"],
                 anchor_3: row["Score 3 when the answer"], anchor_5: row["Score 5 when the answer"] }
      return params unless kind == "multiple_choice"

      params.merge(options: BankWorkbook::LETTERS.each_with_index.to_h { |letter, i| [i.to_s, row["Option #{letter}"]] },
                   correct: BankWorkbook::LETTERS.index(row["Correct option (A-F)"].upcase).to_s)
    end

    # The brief row by its text (as the template's list offers it), prefixed as the screen does. An exact
    # match wins; otherwise a case-insensitive match counts only when it is unique, so two rows that
    # differ only by case never resolve silently to the first (independent test pass, slice D, F6).
    def link_id(section, text)
      rows = section == "role" ? @job.competencies.map { |c| [c.id, c.name] } : @job.activities.map { |a| [a.id, a.description] }
      wanted = text.to_s.strip
      exact = rows.select { |_, t| t.strip == wanted }
      loose = rows.select { |_, t| t.strip.casecmp?(wanted) }
      id = (exact.size == 1 ? exact : (loose.size == 1 ? loose : [])).first&.first
      id && "#{section == 'role' ? 'c' : 'a'}:#{id}"
    end
  end
end
