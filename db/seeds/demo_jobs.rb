# Six sample jobs for the job form (feature 03; D49: "Sample seed jobs follow the house Golongan
# template: Operator G2, Team Leader G3, Supervisor G4, Manager G6, General Manager G7, Direktur G8").
#
# EVERYTHING HERE IS INVENTED DEMO CONTENT for the fictional "PT Contoh Maju Bersama": titles,
# activities, requirements, competencies, and especially the SALARY BANDS and THRESHOLDS, which are
# plausible-looking demo values, not market data and not house defaults (no threshold default
# exists in the spec). Packages follow blueprint §7.1; stage weights are the concept-brief §4.1
# defaults re-normalised (Briefs::StagePlan.default_weights).
#
# All human-readable text is English (owner's rule, 17 Oct 2026: every piece of demo data is in
# English). The Indonesian words that remain are stored codes the app matches on, not text: the
# requirement tiers (wajib / sebaiknya / nilai_tambah, also used as the hash keys below), the
# employment types and relocation values (Job::RELOCATIONS keys), and the Indonesian place names.
#
# Each job is written through the same services as the screens (Briefs::SaveStep, Briefs::Complete),
# so a seed that breaks a brief rule fails loudly instead of planting an invalid demo job.
# Idempotent: a job that already exists with a complete brief is left alone. Jobs are found by
# title, so a database seeded before the English titles keeps its old jobs and gets these six new
# ones beside them. The older demo jobs (the legacy "Warehouse Admin Staff" job in db/seeds.rb and
# the jobs of db/seeds/demo_technical_test.rb) are never read or written here.
require_relative "demo_test_cases"

module DemoJobs
  # Demo thresholds per stage (0-100). Invented for the demo, see the header.
  THRESHOLDS = { "S1" => 60, "S2" => 60, "S3" => 65, "S4" => 60, "S5" => 70 }.freeze

  JOBS = [
    {
      title: "Production Operator", golongan: 2, headcount: 6, employment_type: "kontrak_pkwt", package: 3,
      salary: [5_300_000, 5_900_000], show_salary: true, placements: %w[Bekasi Karawang], relocation: "diutamakan", work_arrangement: "onsite",
      success_90d: "Runs one packaging machine line independently for a full shift, with a reject rate below 2% and no safety incidents.",
      activities: [
        ["Prepare the machine and materials before the shift starts", "Machine preparation checklist completed and signed", 15],
        ["Operate the packaging machine according to the work instructions", "Number of packs meets the hourly target", 40],
        ["Check the quality of the packed output at regular intervals", "Quality check record every 30 minutes", 15],
        ["Record production output and machine downtime", "End-of-shift production report", 10],
        ["Clean the area and the machine to the 5S standard", "Work area passes the 5S inspection", 10],
        ["Report breakdowns or material shortages to the team leader", "Issue report logged in the shift book", 10]
      ],
      wajib: [
        ["Minimum education: senior high school or vocational high school", "Senior or vocational high school diploma listed in the CV", "Have you graduated from senior high school, vocational high school or equivalent?"],
        ["Willing to work three rotating shifts", "Statement of shift availability", "Are you willing to work rotating shifts, including night shifts?"],
        ["At least 6 months of work experience in a production area", "Work history in a factory or production area", nil]
      ],
      sebaiknya: [
        ["Experience operating a packaging or filling machine", "Machine or line named in the work history", 50],
        ["Understands the basics of 5S or occupational health and safety", "5S or OHS training listed in the CV", 30],
        ["Lives near Bekasi or Karawang", "Home address in the CV", 20]
      ],
      nilai_tambah: [["Operator certificate from BNSP", "Certificate number in the CV"]],
      competencies: [
        ["Knowledge of the machine work instructions", "L1", "S2", "Gives the wrong order of the basic operating steps", "Gives the correct order of steps", "Answers correctly and explains the safety checkpoint of each step", nil],
        ["Operating the machine to standard", "L4", "S2", "The sample work has to be redone", "The sample work meets the standard", "The output meets the standard first time and is faster than the standard time", nil],
        ["Honesty in reporting material discrepancies and own mistakes", "I", "S3", "The example told shows a discrepancy was hidden", "Reports the discrepancy when the supervisor asks", "Reports the discrepancy unprompted, immediately, and helps improve the way of working",
         "Tell us about a time you found more or less material than the records showed. What did you do, and when did you report it?"],
        ["Reading simple machine problems", "L2", "S3", "Only says the machine stopped, without a cause", "Finds the cause with the help of questions", "Finds the cause unaided and names its effect on other lines",
         "Tell us about one time your machine stopped suddenly. What was the cause and how did you know?"],
        ["Readiness to work in a shift team", "L4", "S5", "Cannot give an example of teamwork at shift handover", "Gives an example of a tidy shift handover", "Gives an example of a handover that prevented a problem on the next shift",
         "How do you hand over your work to the next shift? Give an example."]
      ]
    },
    {
      title: "Warehouse Team Leader", golongan: 3, headcount: 2, employment_type: "tetap_pkwtt", package: 3,
      salary: [6_800_000, 8_200_000], show_salary: true, placements: %w[Cikarang], relocation: "tidak_perlu", work_arrangement: "onsite",
      success_90d: "Leads a warehouse team of 8 people on one shift, with cycle count stock accuracy of at least 99% and on-time delivery of at least 97%.",
      activities: [
        ["Assign the team's tasks at the start of the shift", "Daily task assignment list", 15],
        ["Supervise the receiving and storage of goods", "Receiving documents match the physical goods", 25],
        ["Supervise order picking and dispatch", "Orders dispatched on schedule", 25],
        ["Run the daily cycle count", "Daily stock discrepancy report", 15],
        ["Train new team members", "New members work independently within two weeks", 10],
        ["Report team performance to the supervisor", "Weekly team performance report", 10]
      ],
      wajib: [
        ["At least 2 years of warehouse experience", "Warehouse work history with length of service", "Do you have at least 2 years of warehouse work experience?"],
        ["Has led a team or worked as a coordinator", "Coordinator or team leader position in the CV", "Have you ever led a work team of at least 3 people?"],
        ["Used to computer-based stock systems", "Name of the WMS/ERP system in the CV", nil]
      ],
      sebaiknya: [
        ["Experience with cycle counts or stock takes", "Stock-take work mentioned in the CV", 40],
        ["Diploma (D3) or higher education", "D3 or bachelor's diploma in the CV", 20],
        ["Holds a forklift operating licence (SIO)", "SIO number in the CV", 40]
      ],
      nilai_tambah: [["FMCG warehouse experience", "Name of an FMCG company in the work history"]],
      competencies: [
        ["Knowledge of the FIFO/FEFO flow and warehouse documents", "L1", "S2", "Cannot explain FIFO/FEFO", "Explains FIFO/FEFO correctly", "Explains and gives an example of when FEFO must take priority", nil],
        ["Finding the cause of stock discrepancies", "L2", "S3", "Names the discrepancy without a cause", "Finds the cause with the help of questions", "Finds the cause unaided and names the other processes affected",
         "Tell us about the largest stock discrepancy you have found. How did you trace its cause?"],
        ["Drawing up the team's work plan", "L4", "S2", "The sample work plan does not meet the target", "The plan meets the target and the headcount", "The plan meets the target with spare people for order peaks", nil],
        ["Training team members", "L5", "S5", "Has never trained anyone", "Has shown a new member how the work is done", "Can name a member who now works independently thanks to their training",
         "Who have you trained, and what can they now do on their own?"],
        ["Honesty about stock discrepancies", "I", "S3", "The example shows a discrepancy was covered up", "Reports the discrepancy when asked", "Reports the discrepancy immediately without being asked and proposes an improvement",
         "Tell us about a time the physical stock was higher than the records. What did you do?"]
      ]
    },
    {
      title: "Production Supervisor", golongan: 4, headcount: 1, employment_type: "tetap_pkwtt", package: 3,
      salary: [9_500_000, 12_500_000], show_salary: false, placements: %w[Karawang], relocation: "wajib", work_arrangement: "onsite",
      success_90d: "Runs two production lines with an OEE of at least 75%, meets at least 95% of the weekly production plan, and has no lost-time work accidents.",
      activities: [
        ["Draw up the daily production schedule from the weekly plan", "Daily production schedule approved", 15],
        ["Supervise the running of two production lines", "Output target per shift met", 30],
        ["Lead the start-of-shift meeting and resolve issues", "Minutes of issues and follow-up actions", 15],
        ["Analyse downtime and rejects", "Weekly root-cause analysis report", 15],
        ["Train and assess the team leaders", "Monthly team leader assessment", 10],
        ["Ensure occupational health and safety is applied in the production area", "Safety findings closed on time", 15]
      ],
      wajib: [
        ["Minimum education: diploma (D3) in engineering or industrial management", "D3 or bachelor's diploma in a relevant field", "Do you hold at least a D3 diploma in engineering or industrial management?"],
        ["At least 2 years of experience as a production supervisor", "Supervisor position and length of service in the CV", "Do you have at least 2 years of experience as a production supervisor?"],
        ["Understands how OEE is calculated", "OEE project or achievement mentioned in the CV", nil]
      ],
      sebaiknya: [
        ["Experience applying lean or kaizen", "Kaizen project with results in the CV", 40],
        ["General OHS Expert (Ahli K3 Umum) certificate", "OHS certificate number in the CV", 30],
        ["Experience in the packaging or food industry", "Name of a similar company in the CV", 30]
      ],
      nilai_tambah: [["Skilled in data analysis with advanced spreadsheets", "Data analysis training or project"]],
      competencies: [
        ["Knowledge of production and safety standards", "L1", "S2", "Gives wrong answers on basic safety standards", "Answers the standards correctly", "Answers correctly and links the standards to the risks on the line", nil],
        ["Root-cause analysis of downtime", "L2", "S3", "Names symptoms without a cause", "Finds the cause with help", "Finds the root cause unaided and names the other processes affected",
         "Tell us about a downtime problem you traced to its root cause. What was the result?"],
        ["Refusing instructions that endanger quality or safety", "L3", "S5", "Follows instructions without weighing the consequences", "Raises an objection once the problem is obvious", "Sees the problem early, raises it with data, then accepts the final decision",
         "Tell us about a time you disagreed with your manager's instruction about production. What did you do and what was the result?"],
        ["Drawing up the production schedule", "L4", "S2", "The sample schedule does not fit the capacity", "The schedule fits the capacity and the orders", "The schedule fits the capacity and leaves time for planned maintenance", nil],
        ["Developing team leaders", "L5", "S5", "Has never coached a subordinate", "Has coached a team leader on one task", "Can name a team leader who now leads a shift alone thanks to their coaching",
         "Who have you developed into a team leader, and what do they now do on their own?"],
        ["Honesty about production figures", "I", "S3", "The example shows figures were adjusted so the target looked met", "Reports the figures as they are when asked", "Reports a target shortfall early without being asked and proposes an improvement",
         "Tell us about a time the production target was not met. How did you report it?"]
      ]
    },
    {
      title: "HR Manager", golongan: 6, headcount: 1, employment_type: "tetap_pkwtt", package: 3,
      salary: [18_000_000, 25_000_000], show_salary: false, placements: %w[Bekasi], relocation: "tidak_perlu", work_arrangement: "hybrid",
      success_90d: "Completes the position and grade map for every employee, cuts the time to fill staff vacancies to under 30 days, and runs payroll without corrections.",
      activities: [
        ["Draw up and run the workforce plan", "Annual workforce plan approved by the board of directors", 20],
        ["Manage recruitment and selection", "Vacancies filled within the target time", 20],
        ["Manage payroll and employment compliance", "Payroll on time with no compliance findings", 20],
        ["Handle industrial relations and the trade union", "Disputes settled bipartitely", 15],
        ["Develop and train the HR team", "HR team development plan on track", 15],
        ["Report HR indicators to the board of directors", "Monthly HR indicator report", 10]
      ],
      wajib: [
        ["Minimum education: bachelor's degree in psychology, law or management", "Bachelor's diploma in a relevant field", "Do you hold at least a bachelor's degree in psychology, law or management?"],
        ["At least 3 years of experience as an HR manager", "HR manager position and length of service in the CV", "Do you have at least 3 years of experience as an HR manager?"],
        ["Understands the Manpower Law and its implementing regulations", "Experience drafting company regulations or a collective labour agreement (PKB)", "Have you ever drafted company regulations or a collective labour agreement (PKB)?"]
      ],
      sebaiknya: [
        ["Experience in a manufacturing company with more than 300 employees", "Company headcount in the CV", 40],
        ["Experience designing a grade structure and wage scale", "Wage structure and scale project in the CV", 35],
        ["HR professional certification from BNSP", "Certificate number in the CV", 25]
      ],
      nilai_tambah: [["Experience leading an HRIS implementation", "Name of the HRIS project in the CV"]],
      competencies: [
        ["Understanding how HR policy links to cost and productivity", "L2", "S3", "Explains policies without their effect", "Explains the effect with the help of questions", "Explains the effect on cost and productivity with figures, unprompted",
         "Tell us about an HR policy you changed. What was its effect on cost and productivity?"],
        ["Assessing and refusing HR decisions with legal risk", "L3", "S5", "Carries out requests without weighing the risk", "Warns about the risk once it is obvious", "Sees the risk early, raises it with the legal basis, and offers another route",
         "Tell us about a time you refused or changed a request from the board of directors about an employee. What was your basis and what was the result?"],
        ["Developing the HR team", "L5", "S5", "Has never developed a subordinate", "Has coached a staff member on one task", "Can name staff who now own a function alone thanks to their coaching",
         "Who in your team now owns a function on their own because you developed them? What could they not do before?"],
        ["Honesty about HR data and budget", "I", "S3", "The example shows data was adjusted to look good", "Reports the data as it is when asked", "Reports own mistakes early without being asked and fixes the process",
         "Tell us about a payroll or employee data error that happened under you. How did you handle it?"],
        ["Knowledge of employment regulations", "L1", "S2", "Gives wrong answers on the basic fixed-term contract (PKWT) rules", "Answers the rules correctly", "Answers correctly and points to the article and its amendments", nil]
      ]
    },
    {
      title: "General Manager, Operations", golongan: 7, headcount: 1, employment_type: "tetap_pkwtt", package: 3,
      salary: [35_000_000, 45_000_000], show_salary: false, placements: %w[Karawang Bekasi], relocation: "wajib", work_arrangement: "onsite",
      success_90d: "Draws up an annual operations plan approved by the board of directors, lowers the production cost per unit by 3%, and sets a weekly performance meeting rhythm across every operations function.",
      activities: [
        ["Draw up the operations plan and budget", "Annual plan and budget approved by the board of directors", 20],
        ["Lead the production, warehouse and maintenance managers", "Every function's objectives met", 25],
        ["Control production and logistics costs", "Cost per unit within budget", 20],
        ["Lead the continuous improvement programme", "Improvement projects with measured savings", 15],
        ["Develop successors for the managers", "A successor candidate for every function", 10],
        ["Report operations performance to the board of directors", "Monthly performance report", 10]
      ],
      wajib: [
        ["Minimum education: bachelor's degree in engineering or management", "Bachelor's diploma in a relevant field", "Do you hold at least a bachelor's degree in engineering or management?"],
        ["At least 5 years of experience leading several operations functions", "Division head or GM position in the CV", "Have you led several operations functions at once for at least 5 years?"],
        ["Experience managing an operations budget", "Size of the budget managed, in the CV", nil]
      ],
      sebaiknya: [
        ["Experience in consumer goods manufacturing", "Name of a similar company in the CV", 40],
        ["Experience leading a plant-wide lean programme", "Results of the lean programme in the CV", 35],
        ["Master's degree", "Master's diploma in the CV", 25]
      ],
      nilai_tambah: [["Experience opening a new plant or line", "Plant opening project in the CV"]],
      competencies: [
        ["Understanding how production, warehouse and cost connect", "L2", "S3", "Sees problems one function at a time", "Connects the functions with the help of questions", "Connects the functions and the cost unaided, with example figures",
         "Tell us about a decision in one function that affected another function. How did you see it?"],
        ["Assessing plans and refusing unreasonable targets", "L3", "S5", "Accepts targets without assessing them", "Raises an objection once the problem is obvious", "Sees the problem early, argues with data, and accepts the final decision",
         "Tell us about a time you refused a target or plan from the board of directors. What was your data and what was the result?"],
        ["Developing successors", "L5", "S5", "Has not prepared a successor", "Has prepared one successor", "Can name several managers who now lead a function thanks to their development",
         "Who did you prepare as your successor, and what position do they hold now?"],
        ["Honesty about performance and budget", "I", "S3", "The example shows figures were adjusted", "Reports things as they are when asked", "Reports budget deviations early without being asked and fixes the process",
         "Tell us about a time your budget went over plan. How and when did you report it?"],
        ["Designing operations work systems", "L4", "S5", "Cannot give an example of a system they designed", "Has designed one procedure that is in use", "Designs systems that run without them and deliver measured results",
         "Tell us about a work system you designed that is still running after you moved on."]
      ]
    },
    {
      title: "Operations Director", golongan: 8, headcount: 1, employment_type: "tetap_pkwtt", package: 3,
      salary: [60_000_000, 80_000_000], show_salary: false, placements: %w[Jakarta], relocation: "tidak_perlu", work_arrangement: "hybrid",
      success_90d: "Sets a three-year operations strategy approved by the shareholders, with cost, quality and safety objectives cascaded to every function.",
      activities: [
        ["Set the operations strategy and objectives", "Three-year strategy approved by the shareholders", 25],
        ["Lead the GMs and operations division heads", "Division objectives met", 20],
        ["Decide on machine and facility investments", "Investment decisions backed by a feasibility study", 20],
        ["Manage operational and compliance risk", "Risk register updated every quarter", 15],
        ["Build a culture of safety and quality", "Safety and quality indicators improving", 10],
        ["Report to the board of directors and the shareholders", "Quarterly report", 10]
      ],
      wajib: [
        ["At least 8 years of experience as an operations director or GM", "Position and length of service in the CV", "Do you have at least 8 years of experience as an operations director or GM?"],
        ["Experience leading an organisation of more than 500 people", "Number of reports in the CV", "Have you ever led an organisation of more than 500 people?"],
        ["Minimum education: bachelor's degree", "Bachelor's diploma in the CV", nil]
      ],
      sebaiknya: [
        ["Experience in a multi-plant manufacturing company", "Number of plants in the CV", 50],
        ["Experience leading an operations transformation", "Results of the transformation in the CV", 30],
        ["Master's degree in management or engineering", "Master's diploma in the CV", 20]
      ],
      nilai_tambah: [["Experience as a board member of a listed company", "Board position in the CV"]],
      competencies: [
        ["Understanding the operations value chain and its effect on profit", "L2", "S3", "Explains operations with no link to profit", "Links operations to profit with help", "Links every operations decision to profit and risk unaided",
         "Tell us about the operations decision with the largest effect on profit. How did you calculate it?"],
        ["Assessing and refusing wrong strategic decisions", "L3", "S5", "Gives no example of a decision they refused", "Raises an objection once the problem is obvious", "Sees the problem early, argues with data, and accepts the final decision",
         "Tell us about a time you disagreed with a decision of the shareholders or the board. What did you do?"],
        ["Building the leaders below them", "L5", "S5", "Has not prepared a replacement leader", "Has prepared one successor", "Can name several leaders who now lead a division thanks to their development",
         "Which leaders have you built, and what do they now lead on their own?"],
        ["Honesty about company performance and risk", "I", "S3", "The example shows risks were hidden from the board", "Reports risks when asked", "Reports risks and own mistakes early without being asked",
         "Tell us about a major risk you reported to the board before being asked. What happened next?"]
      ]
    }
  ].freeze

  module_function

  def run(company:, actor:)
    JOBS.map { |data| seed(data, company:, actor:) }
  end

  def seed(data, company:, actor:)
    job = Job.find_by(title: data[:title], client_company: company)
    # Feature 07 (D60): a job completed before the technical test existed gets its approved demo
    # test here; DemoTestCases.ensure! writes nothing when one is already approved.
    return job.tap { DemoTestCases.ensure!(job, hr: actor) } if job&.brief_complete?

    job ||= Job.new(client_company: company)
    steps(data).each do |step, params|
      result = Briefs::SaveStep.call(job:, step:, params:, actor:)
      raise "seed #{data[:title]} step #{step} refused: #{result.errors.join(' | ')}" unless result.ok?
    end
    DemoTestCases.ensure!(job.reload, hr: actor) # D60: packages 3+ complete only with an approved test
    result = Briefs::Complete.call(job: job.reload, actor:)
    raise "seed #{data[:title]} not complete: #{result.problems.map(&:message).join(' | ')}" unless result.ok?

    job.reload
  end

  def steps(data)
    {
      "1" => { title: data[:title], golongan: data[:golongan].to_s, headcount: data[:headcount].to_s,
               employment_type: data[:employment_type], confidential: "0" },
      "2" => { success_90d: data[:success_90d],
               activities: indexed(data[:activities].map { |d, o, s| { description: d, output: o, share_percent: s.to_s } }) },
      "3" => { salary_min: data[:salary][0].to_s, salary_max: data[:salary][1].to_s, show_salary: data[:show_salary] ? "1" : "0",
               placements: data[:placements], relocation: data[:relocation], work_arrangement: data[:work_arrangement],
               requirements: indexed(requirements(data)) },
      "4" => { package: data[:package].to_s, stage_plan: stage_plan(data[:package]),
               competencies: indexed(data[:competencies].map { |n, l, s, a1, a3, a5, q| { name: n, layer: l, stage_code: s, anchor_1: a1, anchor_3: a3, anchor_5: a5, questions: q } }) }
    }
  end

  def requirements(data)
    data[:wajib].map { |t, e, k| { tier: "wajib", text: t, cv_evidence: e, knockout: k } } +
      data[:sebaiknya].map { |t, e, w| { tier: "sebaiknya", text: t, cv_evidence: e, weight: w.to_s } } +
      data[:nilai_tambah].map { |t, e| { tier: "nilai_tambah", text: t, cv_evidence: e } }
  end

  def stage_plan(package)
    Briefs::StagePlan.default_weights(package).to_h { |code, weight| [code, { weight: weight.to_s, threshold: THRESHOLDS.fetch(code).to_s }] }
  end

  def indexed(rows) = rows.each_with_index.to_h { |row, i| [i.to_s, row] }
end
