# The house workbook theme for caxlsx (excel-export-standard; conventions §0 directive 8: "where
# no theme object exists yet, the first workbook feature creates it" — feature 08 is that
# feature). A spreadsheet cannot read CSS variables, so the literals are duplicated ON PURPOSE;
# each names the CSS custom property it mirrors (public/template/assets/css/hris-zynix.css) so the
# next person can follow the theme when it moves. Calibri 12, left-aligned everywhere, flat fills
# only, the primary at full strength once per sheet (the rule under the masthead).
module ZynixWorkbookTheme
  FONT = "Calibri".freeze
  SIZE = 12
  PRIMARY = "2563EB"      # --primary-rgb: 37, 99, 235
  HEADING = "263442"      # --hris-heading
  TEXT = "384657"         # --hris-text
  LABEL = "536273"        # --hris-label
  MASTHEAD = "F5F7FB"     # --hris-surface-muted on white (light wash)
  TABLE_HEAD = "EEF2F7"   # --hris-table-head-bg
  HAIRLINE = "E9EDF6"     # --hris-hairline / --default-border
  ZEBRA = "FAFBFD"        # --hris-surface-tile on white
  SURFACE = "FFFFFF"      # --hris-surface
  SUCCESS_TINT = "E8F3EC" # .portal-state--success background on white
  SUCCESS_TEXT = "146C43" # .portal-state--success color
  WARNING_TINT = "FDF3E1" # .portal-state--warning background on white
  WARNING_TEXT = "7A4D00" # .gate-box .portal-state--warning color
  DANGER_TINT = "FDEBEC"  # .portal-state--danger background on white
  DANGER_TEXT = "B00004"  # .portal-state--danger color, darkened for print contrast

  BASE = { font_name: FONT, sz: SIZE, alignment: { horizontal: :left, vertical: :top, wrap_text: true } }.freeze

  # Builds the named styles once per workbook (caxlsx styles are workbook-level indexes).
  def self.styles(workbook)
    s = workbook.styles
    # caxlsx's default font (index 0, used by every unstyled cell) is Arial 11; the house is Calibri 12.
    s.fonts.first.name = FONT
    s.fonts.first.sz = SIZE
    hair = { style: :thin, color: HAIRLINE, edges: [:bottom] }
    {
      title: s.add_style(**BASE, sz: SIZE + 2, b: true, fg_color: HEADING, bg_color: MASTHEAD),
      subtitle: s.add_style(**BASE, fg_color: LABEL, bg_color: MASTHEAD),
      rule: s.add_style(**BASE, bg_color: MASTHEAD, border: { style: :medium, color: PRIMARY, edges: [:bottom] }),
      header: s.add_style(**BASE, b: true, fg_color: LABEL, bg_color: TABLE_HEAD, border: hair),
      body: s.add_style(**BASE, fg_color: TEXT, bg_color: SURFACE, border: hair),
      zebra: s.add_style(**BASE, fg_color: TEXT, bg_color: ZEBRA, border: hair),
      success: s.add_style(**BASE, fg_color: SUCCESS_TEXT, bg_color: SUCCESS_TINT, border: hair),
      warning: s.add_style(**BASE, fg_color: WARNING_TEXT, bg_color: WARNING_TINT, border: hair),
      danger: s.add_style(**BASE, fg_color: DANGER_TEXT, bg_color: DANGER_TINT, border: hair),
      footer: s.add_style(**BASE, i: true, fg_color: LABEL, bg_color: MASTHEAD)
    }
  end

  # A masthead row painted across the full table width, then merged (paint before merge: a column
  # left without a cell renders as an unpainted gap, excel-export-standard §1).
  def self.band(sheet, text, style, width)
    row = sheet.add_row([text] + Array.new(width - 1, nil), style: Array.new(width, style), types: Array.new(width, :string))
    sheet.merge_cells(row.cells.first.r + ":" + row.cells.last.r)
    row
  end
end
