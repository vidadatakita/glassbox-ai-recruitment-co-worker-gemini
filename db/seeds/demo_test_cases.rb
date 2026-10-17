# One approved technical test (feature 07, D60 slice 2) for each D49 demo job whose package runs S2.
#
# EVERYTHING HERE IS INVENTED DEMO CONTENT for the fictional "PT Contoh Maju Bersama": the case
# workbooks, their figures, the deliberate errors and the rubrics. No real client data. All text is
# English (owner's rule, 17 Oct 2026); CASES is keyed by the English job titles of DemoJobs::JOBS,
# so a title changed there must change here too. The jobs are operations roles, so each case is an
# operations sheet with planted mistakes the candidate must find and correct (D60's own example is
# an accounting journal; adapted per role).
#
# Written through the same services as the screen (TestCases::SaveVersion as the demo consultant,
# TestCases::Approve as the HR PIC), so a seed that breaks a rule fails loudly. Idempotent: a job
# that already has an approved version is left alone; nothing is written twice.
require "caxlsx"

module DemoTestCases
  # A file-like object for the services (they read the upload the way the form sends it).
  class SeedUpload < StringIO
    attr_reader :original_filename

    def initialize(bytes, filename)
      super(bytes)
      @original_filename = filename
    end
  end

  CONSULTANT_EMAIL = "consultant@glassbox.example".freeze

  # title => [file name, instructions, data sheet rows (first row = header), [[activity index, criterion, weight, a1, a3, a5], ...]]
  CASES = {
    "Production Operator" => [
      "shift-production-report.xlsx",
      "The Data sheet holds the production report of one packaging-line shift. It contains 3 errors: the total, the reject percentage, and one machine downtime hour recorded twice. Mark the wrong rows, write the correct figures on the Answers sheet, and explain the cause in one sentence.",
      [["Hour", "Target (pcs)", "Good output (pcs)", "Reject (pcs)", "Machine downtime (minutes)"],
       ["07:00-08:00", 1200, 1180, 20, 0], ["08:00-09:00", 1200, 1090, 35, 10], ["09:00-10:00", 1200, 1150, 25, 10],
       ["10:00-11:00", 1200, 1195, 15, 0], ["Total", 4800, 4715, 95, 20], ["Reject (%)", nil, nil, "1.2%", nil]],
      [[3, "Accuracy in recording production output", 60, "Does not find the total error", "Finds one or two of the errors", "Finds all three errors with the correct figures"],
       [2, "Understanding quality and rejects", 40, "Reject percentage not corrected", "Percentage corrected without an explanation", "Percentage corrected and the cause explained"]]
    ],
    "Warehouse Team Leader" => [
      "warehouse-stock-reconciliation.xlsx",
      "The Data sheet holds the stock cards and the physical count of 8 items. There are 4 planted discrepancies: one balance miscalculated, one receipt recorded twice, one item under the wrong code, and one real physical discrepancy. For each discrepancy, write the most likely cause and the stock journal correction on the Answers sheet.",
      [["Code", "Item", "Opening balance", "In", "Out", "System balance", "Physical count"],
       ["BRG-101", "Carton 40x30", 500, 200, 350, 350, 350], ["BRG-102", "Brown packing tape", 120, 60, 90, 100, 90],
       ["BRG-103", "Wooden pallet", 40, 20, 15, 45, 45], ["BRG-104", "Stretch film", 75, 50, 40, 135, 85],
       ["BRG-105", "Shelf label", 300, 0, 120, 180, 180], ["BRG-106", "Bubble wrap", 60, 30, 30, 60, 54],
       ["BRG-170", "Carton 50x40", 210, 100, 160, 150, 150], ["BRG-108", "Work gloves", 200, 100, 150, 150, 150]],
      [[1, "Finding and explaining stock discrepancies", 50, "No discrepancy found", "Two or three discrepancies found", "All four discrepancies found with a plausible cause"],
       [2, "Correcting the records by the procedure", 30, "No correction written", "Correction written without supporting documents", "Correction written in full with the required documents"],
       [5, "Follow-up with the team", 20, "No follow-up", "A general follow-up", "A specific follow-up that prevents the discrepancy recurring"]]
    ],
    "Production Supervisor" => [
      "production-plan-vs-actual.xlsx",
      "The Data sheet compares the planned and actual production of two lines over one week. Recalculate the achievement per day, find the 3 wrong figures, then write two actions for the day with the lowest achievement on the Answers sheet.",
      [["Day", "Line", "Plan (pcs)", "Actual (pcs)", "Achievement"],
       ["Monday", "A", 5000, 4800, "96%"], ["Monday", "B", 4000, 3200, "90%"], ["Tuesday", "A", 5000, 5100, "102%"],
       ["Tuesday", "B", 4000, 3900, "98%"], ["Wednesday", "A", 5000, 4100, "92%"], ["Wednesday", "B", 4000, 3950, "99%"]],
      [[0, "Reading plan and actual data", 50, "Achievement not recalculated", "Some of the wrong figures found", "All three wrong figures found and recalculated correctly"],
       [1, "The right corrective actions", 50, "Actions unrelated to the data", "General actions", "Two specific actions on the cause in the line concerned"]]
    ],
    "HR Manager" => [
      "overtime-and-turnover-summary.xlsx",
      "The Data sheet holds a summary of overtime hours and leavers per department for one quarter. There are 3 formula errors (the total, the average and the turnover rate). Correct the figures on the Answers sheet and write one recommendation for the department with the highest risk.",
      [["Department", "Average headcount", "Leavers", "Turnover", "Overtime hours"],
       ["Production", 180, 18, "10%", 2400], ["Warehouse", 60, 9, "12%", 900], ["Logistics", 40, 2, "5%", 300],
       ["Administration", 20, 1, "5%", 60], ["Total", 300, 30, "8%", 3560]],
      [[0, "Accuracy of the HR data analysis", 60, "No error found", "One or two errors corrected", "All three errors corrected with the right formula"],
       [1, "Data-based recommendation", 40, "Recommendation unrelated to the data", "A general recommendation", "A specific recommendation for the highest-risk department"]]
    ],
    "General Manager, Operations" => [
      "monthly-operations-kpi.xlsx",
      "The Data sheet holds three months of operations KPIs (production, on-time delivery, cost per unit). Two figures are inconsistent across columns and one trend is described the wrong way round. Find all three and write three priorities for next month on the Answers sheet.",
      [["Month", "Production (thousand pcs)", "On time", "Cost per unit (Rp)", "Note"],
       ["July", 410, "96%", 1850, "Stable"], ["August", 395, "93%", 1920, "Cost down"], ["September", 430, "97%", 1880, "Production down"]],
      [[0, "Reading cross-functional KPIs", 50, "No inconsistency found", "Some found", "All three inconsistencies found and explained"],
       [1, "Setting priorities", 50, "Priorities unrelated to the data", "General priorities", "Three measurable priorities that answer the findings"]]
    ],
    "Operations Director" => [
      "opex-budget-vs-actual.xlsx",
      "The Data sheet holds the budget and actual operating costs for one half-year. There are 2 wrong sums and 1 line booked under the wrong category. Correct the figures and write a one-paragraph summary for the board of directors on the Answers sheet.",
      [["Cost line", "Category", "Budget (Rp million)", "Actual (Rp million)", "Variance"],
       ["Plant electricity", "Utilities", 1200, 1310, 110], ["Forklift rental", "Utilities", 300, 280, -20],
       ["Machine maintenance", "Maintenance", 650, 720, 60], ["Transport", "Logistics", 900, 870, -30],
       ["Total", nil, 3050, 3180, 120]],
      [[0, "Sharpness of the budget analysis", 50, "No error found", "Some errors corrected", "Every error corrected correctly"],
       [1, "Communication to the board of directors", 50, "Summary unclear", "Summary correct but long", "Summary short, with figures, and naming the decision required"]]
    ]
  }.freeze

  module_function

  # Ensures one approved version for the job, when its package runs S2. Returns the version or nil.
  def ensure!(job, hr:)
    return unless TestCases::Requirement.applies?(job)

    current = TechnicalTestCase.current_for(job)
    return current if current

    data = CASES.fetch(job.title) { raise "no demo test case for #{job.title}" }
    save = TestCases::SaveVersion.call(job:, actor: consultant, params: params_for(job, data))
    raise "demo test case #{job.title} refused: #{save.errors.join(' | ')}" unless save.ok?

    approve = TestCases::Approve.call(test_case: save.test_case, actor: hr)
    raise "demo test case #{job.title} not approved: #{approve.errors.join(' | ')}" unless approve.ok?

    save.test_case.reload
  end

  def consultant
    User.find_by(email_address: CONSULTANT_EMAIL) || User.where(role: "hr_admin").order(:id).first ||
      User.create!(email_address: CONSULTANT_EMAIL, name: "Rangga Saputra", role: "hr_admin", client_company: ClientCompany.first, password: SecureRandom.base58(24))
  end

  def params_for(job, (filename, instructions, rows, criteria))
    activities = job.activities.to_a
    { instructions:, time_limit_minutes: "35", answer_types_submitted: "1", answer_types: %w[xlsx],
      case_file: SeedUpload.new(workbook(instructions, rows), filename),
      criteria: criteria.each_with_index.to_h do |(index, name, weight, a1, a3, a5), i|
        [i.to_s, { activity_id: activities.fetch(index).id.to_s, name:, weight: weight.to_s, anchor_1: a1, anchor_3: a3, anchor_5: a5 }]
      end }
  end

  # Three sheets: Instructions, Data (with the planted errors), Answers (empty, for the candidate).
  # No app code reads these sheet names (grep app/ for them); only the seed test asserts them.
  def workbook(instructions, rows)
    package = Axlsx::Package.new
    book = package.workbook
    bold = book.styles.add_style(b: true)
    book.add_worksheet(name: "Instructions") do |sheet|
      sheet.add_row(["Case study (sample data, invented figures)"], style: bold)
      sheet.add_row([instructions])
    end
    book.add_worksheet(name: "Data") do |sheet|
      sheet.add_row(rows.first, style: bold)
      rows.drop(1).each { |row| sheet.add_row(row) }
    end
    book.add_worksheet(name: "Answers") { |sheet| sheet.add_row(["Row / line", "Correct figure", "Explanation"], style: bold) }
    package.to_stream.read
  end
end
