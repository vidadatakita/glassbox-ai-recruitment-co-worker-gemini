module ScreeningReport
  # Formula-injection guard for every TEXT cell of the report workbook (D62 h8; OWASP CSV
  # injection). A cell whose text starts with = + - @ TAB or CR could be evaluated as a formula
  # once a user edits it in Excel or re-saves it as CSV; prefixing a single quote keeps it text.
  # Candidate-controlled text reaches this workbook (the AI quotes the CV; the HR PIC types the
  # user's name), so the escape is applied to EVERY text cell, not only to fields thought risky.
  # Numbers and the workbook's own formulas never pass through here.
  module CellEscape
    PREFIXES = ["=", "+", "-", "@", "\t", "\r"].freeze

    module_function

    def call(value)
      text = value.to_s
      PREFIXES.any? { |p| text.start_with?(p) } ? "'#{text}" : text
    end
  end
end
