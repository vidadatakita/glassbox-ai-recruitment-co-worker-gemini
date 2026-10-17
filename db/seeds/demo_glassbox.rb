# GlassBox demo data for the AI Builder Cup (plan task A6). EVERYTHING HERE IS INVENTED: the
# company, the three vacancies, the twenty-five applicants, their CV texts, employers, schools,
# scores and notes. No real candidate, client or employee data (project rule). No AI is called:
# every AI row carries the model id MODEL_ID so nobody can mistake it for a model's judgement.
#
# Self-contained on purpose: it requires no other seed file, so the team can swap the demo to
# this seed in db/seeds.rb with one `require_relative "seeds/demo_glassbox"` and one `.run` call.
#
# What it builds (FLOW v2.1 §1 steps, read with docs/GLOSSARY-EN.md):
#   step 3   three vacancies with an approved brief, headcount, salary band at or above the
#            Kota Tangerang 2026 minimum wage, the tier pass score locked on the S1 stage, the
#            S1+S2 gate open and the applicant portal open
#   step 4   25 applications with consent recorded and a status link issued (one token printed)
#   step 5   one approved technical test on the Accounting Supervisor vacancy (a journal with three
#            planted errors, three rubric criteria with 1/3/5 anchors); four applicants sent an
#            answer: two scored above the pass score, one below, one awaiting the reviewer
#   step 6   two CVs held at "Awaiting review": redacted text prepared, nothing sent
#   step 7   21 CVs screened against the brief's rubric with a verbatim quote per judgement, and
#            ONE CV whose AI row carries a planted quote that is NOT in the CV, so the evidence
#            check marks it "unverified" and the review queue holds it (the video's step 7 beat)
#   step 9   AI advice rows beside the HR owner's choice: Continue, Follow AI advice (including a
#            reject with a written reason), Do not continue with a reason, and two still waiting
#   step 10  one candidate at Interview 1 with two assessor links: one scored, one still open
#
# Hand scores: HAND holds, per applicant and requirement code, the judgement a person gave and the
# CV line it rests on. docs/evaluation/hand-scores.csv is GENERATED from HAND (`hand_scores_csv`),
# so the seed and the evaluation file cannot drift; test/engine/cup ties them out.
#
# Database rules this seed respects on purpose (they are triggers and CHECK constraints):
#   - TENANCY=single allows exactly one client company, so the seed uses the install's company
#     and only creates "PT Terang Nusantara" when none exists yet. Renaming the seeded company is
#     the team's call in db/seeds.rb; a mismatch is printed, never patched silently.
#   - score_entries by the AI actor (id 0) must name a model id; decisions with basis "manual"
#     need an actor and a note; a "do not continue" direction always needs a note.
#   - the should-have weights of each rubric sum to exactly 100 (Screening::Score refuses otherwise).
# Idempotent: a vacancy that already exists (by title) is left alone.
require "caxlsx"

module DemoGlassbox
  # A file-like object for the services (they read an upload the way the form sends it).
  class SeedUpload < StringIO
    attr_reader :original_filename

    def initialize(bytes, filename)
      super(bytes)
      @original_filename = filename
    end
  end

  COMPANY = { name: "PT Terang Nusantara", address: "Jl. Industri Terang Blok C No. 21", city: "Kota Tangerang",
              contact_email: "hr@terangnusantara.example" }.freeze
  # Kota Tangerang minimum wage 2026 (UMK) is Rp 5,399,405.69 (Keputusan Gubernur Banten 703/2025).
  # Salary columns are integer rupiah, so the floor is rounded UP: a band floor of 5,399,405 would
  # sit 69 cents BELOW the legal minimum. Do not round down.
  UMK_2026 = 5_399_406
  MODEL_ID = "demo-no-ai (sample data)".freeze
  REVIEWER_NAME = "the reviewer".freeze

  # Tier pass scores (screening standard P-09): T2 65, T4 60. Locked on the S1 stage at open.
  JOBS = {
    acc: {
      title: "Accounting Supervisor", tier: "T2", golongan: 4, package: 3, threshold: 65, headcount: 1,
      employment_type: "tetap_pkwtt", salary: [8_000_000, 11_000_000],
      success_90d: "Monthly close delivered by working day 5 with reconciled bank and cash accounts.",
      activities: [["Prepare monthly journals and financial statements", "Financial statements on time", 35],
                   ["Reconcile bank and cash accounts", "Every difference explained", 25],
                   ["Lead and review the work of the accounting staff", "Fewer staff errors", 15],
                   ["Prepare monthly tax payments and filings", "Taxes paid and filed on time", 15],
                   ["Answer auditors' and management's questions on the figures", "Questions answered within two days", 10]],
      requirements: [["M1", "wajib", "At least a D3 (associate) degree in Accounting", "Accounting diploma or degree in the CV", nil],
                     ["S1", "sebaiknya", "Experience preparing journals and bank reconciliations", "Journals or reconciliations in the work history", 60],
                     ["S2", "sebaiknya", "Advanced Microsoft Excel", "Excel skills named", 40],
                     ["N1", "nilai_tambah", "Experience leading an accounting team", "Leading staff named", nil]],
      knockouts: ["Willing to work on site in Kota Tangerang?", "At least two years of accounting experience?"],
      # Step 5: the case file is built from the brief's activities (journals, reconciliation, review).
      # criteria: [activity index, name, weight, anchor 1, anchor 3, anchor 5]; weights sum to 100.
      test_case: {
        file: "monthly-journal-case.xlsx", time_limit_minutes: 35,
        instructions: "The Data sheet holds one month of journal entries for a small trading company with THREE planted errors: one debit and credit that do not balance, one bank receipt posted twice, and one expense posted to the wrong account. Mark each wrong row, write the correct figures on the Answer sheet, and explain each correction in one sentence for a junior staff member.",
        rows: [["Date", "Account", "Debit", "Credit"],
               ["01-09-2026", "Cash", 5_000_000, nil], ["01-09-2026", "Sales revenue", nil, 5_500_000],
               ["03-09-2026", "Bank", 12_000_000, nil], ["03-09-2026", "Accounts receivable", nil, 12_000_000],
               ["03-09-2026", "Bank", 12_000_000, nil], ["03-09-2026", "Accounts receivable", nil, 12_000_000],
               ["07-09-2026", "Office supplies", 850_000, nil], ["07-09-2026", "Bank", nil, 850_000],
               ["15-09-2026", "Salaries expense", 48_000_000, nil], ["15-09-2026", "Bank", nil, 48_000_000],
               ["22-09-2026", "Accounts receivable", 2_400_000, nil], ["22-09-2026", "Electricity expense", nil, 2_400_000]],
        criteria: [[0, "Finds the journal errors", 36, "No error found", "One or two errors found", "All three errors found with the correct figures"],
                   [1, "Reconciles the bank movements", 32, "Duplicate receipt not noticed", "Duplicate noticed, bank balance not recomputed", "Duplicate removed and bank balance recomputed"],
                   [2, "Explains the corrections for the team", 32, "No explanation", "Explanation without the reason", "Each correction explained with its reason in plain words"]]
      },
      competencies: [["S3", "L4", "Runs the monthly close", "Close is late with many corrections", "Close on time with few corrections",
                      "Close on time, clean, and used by management", "Walk us through the last monthly close you led."],
                     ["S3", "I", "Integrity of financial data", "Hides a difference", "Reports a difference to the manager",
                      "Traces, explains and prevents repeat differences", "What do you do when you find a cash difference?"],
                     ["S5", "L5", "Coaches accounting staff", "Does the staff's work alone", "Checks and corrects",
                      "Trains staff until errors fall", "How do you make a new staff member independent within a month?"],
                     ["S5", "L1", "Knows the accounting standards", "Cannot name the rule behind an entry", "Names the rule for common entries",
                      "Explains the rule and its exceptions for any entry", "Which standard governs revenue recognition, and how do you apply it?"],
                     ["S5", "L2", "Understands the business behind the figures", "Reads figures without context", "Links figures to sales and costs",
                      "Explains every movement from the business events", "Our margin fell two points last month. Where would you look first?"],
                     ["S5", "L3", "Judges when to escalate", "Escalates nothing or everything", "Escalates the large differences",
                      "Escalates by materiality and risk, with a proposal", "Tell us about a difference you decided not to escalate, and why."]]
    },
    adm: {
      # Package 3 (17 Oct 2026): the seed builds S1, S2, S3 and S5 for every vacancy, which is package 3's
      # ladder (Briefs::StagePlan). Seeded as package 2 it showed a technical-test gate whose pages answer
      # 404, because those pages follow the package. Package 3 is a recommended package for grade 2.
      title: "Admin Staff", tier: "T4", golongan: 2, package: 3, threshold: 60, headcount: 2,
      employment_type: "kontrak_pkwt", salary: [UMK_2026, 6_200_000],
      success_90d: "Daily document log complete and every incoming letter filed within one working day.",
      activities: [["Record incoming and outgoing documents", "Complete daily log", 30],
                   ["Prepare purchase orders and delivery notes in Excel", "Documents without errors", 30],
                   ["Support the team with scheduling and filing", "Files found within one minute", 15],
                   ["Answer the office phone and direct visitors", "Every caller directed the same day", 15],
                   ["Keep the office supplies stocked", "No supply runs out", 10]],
      requirements: [["M1", "wajib", "At least a senior high school (SMA/SMK) diploma", "SMA, SMK or higher in the CV", nil],
                     ["S1", "sebaiknya", "Experience with office administration", "Administrative work in the work history", 50],
                     ["S2", "sebaiknya", "Microsoft Excel and Word", "Excel or Word named", 50],
                     ["N1", "nilai_tambah", "Experience with purchase orders or delivery notes", "Purchase orders or delivery notes named", nil]],
      knockouts: ["Willing to work on site in Kota Tangerang?", "Available to start within one month?"],
      # Step 5 (17 Oct 2026): a vacancy with a technical-test stage opens only with an approved test
      # (Portal::WindowChange, TestCases::Readiness), so every demo vacancy carries one.
      test_case: {
        file: "document-log-case.xlsx", time_limit_minutes: 25,
        instructions: "The Data sheet is one week of the incoming document log and two purchase orders with THREE planted errors: one letter logged twice, one purchase order whose total does not match its lines, and one delivery note filed under the wrong supplier. Find each error, correct it on the Answers sheet, and write one sentence per correction.",
        rows: [["Date", "Document", "Supplier", "Amount"],
               ["05-10-2026", "Incoming letter 041", "PT Sinar Kertas", nil], ["05-10-2026", "Incoming letter 041", "PT Sinar Kertas", nil],
               ["06-10-2026", "Purchase order PO-118 line 1", "CV Mitra Office", 1_200_000], ["06-10-2026", "Purchase order PO-118 line 2", "CV Mitra Office", 800_000],
               ["06-10-2026", "Purchase order PO-118 total", "CV Mitra Office", 2_100_000],
               ["08-10-2026", "Delivery note DN-77", "PT Sinar Kertas", nil], ["08-10-2026", "Purchase order PO-119 total", "PT Prima Toner", 950_000]],
        criteria: [[0, "Keeps the document log clean", 40, "Duplicate not noticed", "Duplicate noticed, not removed", "Duplicate removed and the log renumbered"],
                   [1, "Checks purchase order figures", 40, "Total not checked", "Wrong total found, not corrected", "Total corrected to 2,000,000 with the lines shown"],
                   [2, "Files and explains each correction", 20, "No explanation", "Correction without the reason", "Each correction explained in one plain sentence"]]
      },
      competencies: [["S3", "L1", "Knows document and filing rules", "Files without a system", "Follows the filing system",
                      "Improves the filing system and explains it", "How do you file a letter that fits two folders?"],
                     ["S3", "L4", "Works accurately in Excel", "Many typing errors", "Few errors, checks totals",
                      "No errors, uses formulas to check", "Show us how you would check a purchase order total."],
                     ["S5", "I", "Handles documents with integrity", "Changes a document without telling", "Reports a wrong document",
                      "Reports, corrects and records the change", "What do you do when a supplier asks you to change a date?"]]
    },
    area: {
      title: "Area Supervisor", tier: "T2", golongan: 4, package: 3, threshold: 65, headcount: 1,
      employment_type: "tetap_pkwtt", salary: [7_500_000, 10_000_000],
      success_90d: "Visits every outlet in the area twice a month with a written visit report each time.",
      activities: [["Visit and audit the outlets in the area", "Visit report per outlet", 35],
                   ["Coach outlet leaders on sales and stock routines", "Routines followed", 25],
                   ["Report area sales and stock figures weekly", "Weekly report on time", 15],
                   ["Handle customer complaints escalated by the outlets", "Every complaint closed within a week", 15],
                   ["Plan the outlet staffing roster with the leaders", "No outlet understaffed", 10]],
      # M1 asks only what a CV can show (16 Oct agreement check: the compound "licence and willing to
      # travel" was judged not met on 6 of 7 CVs that name a licence, because no CV states the
      # willingness). The willingness is the first knockout question, answered by the applicant.
      requirements: [["M1", "wajib", "Holds a driving licence", "A driving licence (SIM A, B or C) named in the CV", nil],
                     ["S1", "sebaiknya", "Experience supervising several outlets or branches", "Multi-outlet supervision in the work history", 60],
                     ["S2", "sebaiknya", "Experience with stock counts and sales reporting", "Stock counts or sales reports named", 40],
                     ["N1", "nilai_tambah", "Experience coaching outlet leaders", "Coaching or training outlet leaders named", nil]],
      knockouts: ["Willing to travel across Tangerang and Serang every week?", "Holds a valid driving licence?"],
      test_case: {
        file: "outlet-visit-case.xlsx", time_limit_minutes: 30,
        instructions: "The Data sheet is one week of visit and stock figures from four outlets with THREE planted problems: one outlet whose closing stock does not follow from opening stock and sales, one outlet not visited this week, and one sales figure entered in the wrong week. Find each problem, write the corrected figures on the Answers sheet, and add one coaching action per outlet.",
        rows: [["Outlet", "Visited", "Opening stock", "Sales", "Closing stock"],
               ["Outlet Cikokol", "Yes", 420, 130, 290], ["Outlet Karawaci", "Yes", 380, 95, 305],
               ["Outlet Serpong", "No", 510, 160, 350], ["Outlet Ciledug", "Yes", 300, 410, 290]],
        criteria: [[0, "Audits the outlet figures", 40, "No problem found", "One or two problems found", "All three problems found with the correct figures"],
                   [1, "Plans the coaching per outlet", 30, "No action", "Generic action for all outlets", "One concrete action per outlet tied to its figures"],
                   [2, "Reports the area clearly", 30, "No summary", "Summary without figures", "Weekly summary with the corrected figures and the missed visit"]]
      },
      competencies: [["S3", "L1", "Knows retail stock routines", "Cannot describe a stock count", "Describes the stock count steps",
                      "Explains the routines and why each step matters", "Walk us through a stock count at an outlet."],
                     ["S3", "L2", "Understands outlet performance", "Reads sales without context", "Links sales to stock and staffing",
                      "Explains each outlet's figures from its situation", "One outlet's sales fell 20%. What do you check?"],
                     ["S3", "L3", "Judges priorities across outlets", "Visits in a fixed order only", "Visits the weakest outlets first",
                      "Plans visits by risk and opportunity each week", "You have three urgent outlets and one day. How do you plan it?"],
                     ["S3", "L4", "Audits an outlet", "No written findings", "Written findings for each visit",
                      "Findings with figures and an agreed action", "What goes into your visit report?"],
                     ["S5", "L5", "Coaches outlet leaders", "Gives orders only", "Shows the routine once",
                      "Coaches until the leader runs it alone", "How do you make an outlet leader run the stock count alone?"],
                     ["S5", "I", "Reports honestly", "Hides a bad result", "Reports the bad result",
                      "Reports, explains and proposes a fix", "Tell us about a time you reported a bad figure to your manager."]]
    }
  }.freeze

  # CV text template. Only evidence sections (the parts the AI may see) carry content; the personal
  # section is there so the redaction demo (step 6) has something to strip. Written WITHOUT gender
  # pronouns and WITHOUT religious institution names on purpose: the evidence-section pass does not
  # redact those words (F-27 trade-off), so a demo CV must not rely on it.
  CV = <<~CV.freeze
    CURRICULUM VITAE
    Full Name : %<name>s
    Date of Birth : %<city>s, %<dob>s
    Gender : %<gender>s
    Address : Jl. Contoh No. %<house>d RT 01/RW 02, %<city>s
    Phone : %<phone>s
    Email : %<email>s
    WORK EXPERIENCE
    %<years>s  %<role>s at %<employer>s, %<city>s
    %<line1>s
    %<line2>s
    EDUCATION
    %<education>s
    SKILLS
    %<skills>s
  CV

  # Per applicant: key, name, gender word (redaction demo only), city, CV fields, and the hand
  # judgements. hand: requirement code => [judgement, quote]. The quote is the CV fragment the
  # judgement rests on; a positive judgement with an empty quote is NOT allowed by the evidence
  # check, so every positive row names one. state: :screened (AI row + decision), :held (awaiting
  # a reviewer's release, nothing sent), :unverified (AI row with ONE planted fake quote).
  # step9: [advice, ai_score, choice, note] or nil (no AI advice asked yet). test: [:scored, [r1, r2, r3]]
  # (answer sent and scored 1-5 per criterion), [:answered, nil] (sent, awaiting the reviewer), or absent.
  PEOPLE = [
    # ---- Accounting Supervisor (10) ------------------------------------------------------------
    { job: :acc, key: "ACC-01", name: "Adrian Wicaksono", gender: "Male", city: "Kota Tangerang",
      years: "2019 - present", role: "Accounting Supervisor", employer: "PT Sinar Logistik Nusantara",
      line1: "Prepares the monthly journals, financial statements and bank reconciliations for three entities",
      line2: "Leads a team of four accounting staff and reviews every journal before posting",
      education: "Bachelor of Accounting, Universitas Mitra Bangsa, graduated 2014",
      skills: "Advanced Microsoft Excel (pivot tables, VLOOKUP, Power Query), Accurate, SAP Business One",
      hand: { "M1" => ["met", "Bachelor of Accounting"], "S1" => ["3", "Prepares the monthly journals, financial statements and bank reconciliations for three entities"],
              "S2" => ["3", "Advanced Microsoft Excel (pivot tables, VLOOKUP, Power Query)"], "N1" => ["3", "Leads a team of four accounting staff"] },
      state: :screened, step9: ["lanjut", 86, "ikut_ai", nil], interview: true, test: [:scored, [5, 4, 5]] },
    { job: :acc, key: "ACC-02", name: "Bella Kusumawardhani", gender: "Female", city: "Kota Tangerang",
      years: "2020 - present", role: "Senior Accounting Staff", employer: "PT Karya Beton Mandiri",
      line1: "Posts daily journals and prepares the monthly bank reconciliation for two accounts",
      line2: "Prepares the VAT and withholding tax reports every month",
      education: "Diploma (D3) in Accounting, Politeknik Tangerang Raya, graduated 2017",
      skills: "Microsoft Excel (pivot tables, SUMIFS), Accurate, e-Faktur",
      hand: { "M1" => ["met", "Diploma (D3) in Accounting"], "S1" => ["3", "Posts daily journals and prepares the monthly bank reconciliation for two accounts"],
              "S2" => ["2", "Microsoft Excel (pivot tables, SUMIFS)"], "N1" => ["0", ""] },
      state: :screened, step9: ["lanjut", 78, "lanjut", nil], test: [:scored, [3, 3, 4]] },
    { job: :acc, key: "ACC-03", name: "Chandra Pamungkas", gender: "Male", city: "Kabupaten Tangerang",
      years: "2016 - present", role: "Finance Manager", employer: "PT Delta Pangan Sejahtera",
      line1: "Owns the monthly close, consolidation and cash flow forecast for a group of five companies",
      line2: "Manages a finance and accounting team of twelve people",
      education: "Master of Accounting, Universitas Cendana, graduated 2015",
      skills: "Advanced Microsoft Excel and Power BI, SAP FI/CO, Oracle NetSuite",
      hand: { "M1" => ["met", "Master of Accounting"], "S1" => ["3", "Owns the monthly close, consolidation and cash flow forecast for a group of five companies"],
              "S2" => ["3", "Advanced Microsoft Excel and Power BI"], "N1" => ["3", "Manages a finance and accounting team of twelve people"] },
      state: :screened, step9: ["lanjut", 90, "tidak_lanjut", "Two grades above the vacancy (manager level, twelve reports); the role would be a step down and the band does not reach the current salary."] },
    { job: :acc, key: "ACC-04", name: "Dinda Prameswari", gender: "Female", city: "Kota Tangerang Selatan",
      years: "2021 - present", role: "Accounting Staff", employer: "CV Mekar Abadi Teknik",
      line1: "Records purchase and sales journals and matches supplier invoices to delivery notes",
      line2: "Assists the supervisor with the monthly bank reconciliation",
      education: "Bachelor of Accounting, Universitas Mitra Bangsa, graduated 2020",
      skills: "Microsoft Excel (VLOOKUP, pivot tables), Jurnal.id",
      hand: { "M1" => ["met", "Bachelor of Accounting"], "S1" => ["2", "Assists the supervisor with the monthly bank reconciliation"],
              "S2" => ["2", "Microsoft Excel (VLOOKUP, pivot tables)"], "N1" => ["0", ""] },
      state: :screened, step9: ["lanjut", 67, nil, nil], test: [:answered, nil] },
    { job: :acc, key: "ACC-05", name: "Erlangga Saputra", gender: "Male", city: "Kota Tangerang",
      years: "2018 - present", role: "Tax Staff", employer: "KAP Nusantara Rekan",
      line1: "Prepares monthly and annual tax returns for twenty client companies",
      line2: "Reviews client general ledgers before the tax filing",
      education: "Bachelor of Accounting, Universitas Cendana, graduated 2017",
      skills: "Microsoft Excel (pivot tables), e-SPT, e-Faktur",
      hand: { "M1" => ["met", "Bachelor of Accounting"], "S1" => ["1", "Reviews client general ledgers before the tax filing"],
              "S2" => ["2", "Microsoft Excel (pivot tables)"], "N1" => ["0", ""] },
      state: :screened, step9: ["tidak_lanjut", 54, "ikut_ai", "Tax filing experience only; no journal preparation or bank reconciliation in the work history, which the role needs from day one."] },
    { job: :acc, key: "ACC-06", name: "Fitriani Rahmadani", gender: "Female", city: "Kota Tangerang",
      years: "2022 - present", role: "Finance Administrator", employer: "Toko Bangunan Sumber Jaya",
      line1: "Records daily cash receipts and payments in a cash book",
      line2: "Files supplier invoices and prepares the weekly payment list",
      education: "Diploma (D3) in Accounting, Politeknik Tangerang Raya, graduated 2021",
      skills: "Microsoft Excel (basic formulas), Microsoft Word",
      hand: { "M1" => ["met", "Diploma (D3) in Accounting"], "S1" => ["1", "Records daily cash receipts and payments in a cash book"],
              "S2" => ["1", "Microsoft Excel (basic formulas)"], "N1" => ["0", ""] },
      state: :screened, step9: nil },
    { job: :acc, key: "ACC-07", name: "Gilang Mahendra", gender: "Male", city: "Kota Serang",
      years: "2017 - present", role: "Warehouse Staff", employer: "PT Logistik Cepat Banten",
      line1: "Receives and dispatches goods and keeps the daily stock card",
      line2: "Runs the monthly stock count with the warehouse supervisor",
      education: "Senior High School (SMA Negeri 3 Serang), graduated 2016",
      skills: "Microsoft Excel (data entry), forklift licence",
      hand: { "M1" => ["not_met", ""], "S1" => ["0", ""], "S2" => ["1", "Microsoft Excel (data entry)"], "N1" => ["0", ""] },
      state: :screened, step9: nil },
    { job: :acc, key: "ACC-08", name: "Hanifah Zahra", gender: "Female", city: "Kota Tangerang",
      years: "2019 - present", role: "Accounting Supervisor", employer: "PT Agro Lestari Makmur",
      line1: "Prepares the monthly journals and the bank reconciliation for the plantation entity",
      line2: "Supervises two accounting staff and reviews their postings weekly",
      education: "Bachelor of Accounting, Universitas Mitra Bangsa, graduated 2015",
      skills: "Advanced Microsoft Excel (pivot tables, macros), Accurate",
      hand: { "M1" => ["met", "Bachelor of Accounting"], "S1" => ["3", "Prepares the monthly journals and the bank reconciliation for the plantation entity"],
              "S2" => ["3", "Advanced Microsoft Excel (pivot tables, macros)"], "N1" => ["2", "Supervises two accounting staff"] },
      state: :unverified, step9: nil },
    { job: :acc, key: "ACC-09", name: "Irfan Nugraha", gender: "Male", city: "Kota Tangerang",
      years: "2020 - present", role: "Accounting Staff", employer: "PT Retail Prima Indonesia",
      line1: "Posts sales journals from the point-of-sale system and reconciles card settlements with the bank",
      line2: "Prepares the monthly fixed-asset register",
      education: "Bachelor of Accounting, Universitas Cendana, graduated 2019",
      skills: "Microsoft Excel (pivot tables, VLOOKUP), SAP Business One",
      hand: { "M1" => ["met", "Bachelor of Accounting"], "S1" => ["3", "Posts sales journals from the point-of-sale system and reconciles card settlements with the bank"],
              "S2" => ["2", "Microsoft Excel (pivot tables, VLOOKUP)"], "N1" => ["0", ""] },
      state: :held, step9: nil },
    { job: :acc, key: "ACC-10", name: "Jasmine Halimah", gender: "Female", city: "Kota Tangerang",
      years: "2018 - present", role: "Cost Accountant", employer: "PT Tekstil Mulia Sentosa",
      line1: "Prepares the monthly cost of goods journals and reconciles inventory to the general ledger",
      line2: "Coaches one junior accountant on costing routines",
      education: "Bachelor of Accounting, Universitas Mitra Bangsa, graduated 2016",
      skills: "Advanced Microsoft Excel (pivot tables, Power Query), SAP FI/CO",
      hand: { "M1" => ["met", "Bachelor of Accounting"], "S1" => ["2", "Prepares the monthly cost of goods journals and reconciles inventory to the general ledger"],
              "S2" => ["3", "Advanced Microsoft Excel (pivot tables, Power Query)"], "N1" => ["1", "Coaches one junior accountant on costing routines"] },
      # Test scored below the pass score: the AI advice says "do not continue"; the HR owner has not
      # chosen yet, and following that advice on a reject requires a written reason (step 9 rule).
      state: :screened, step9: ["tidak_lanjut", 48, nil, nil], test: [:scored, [2, 2, 3]] },
    # ---- Admin Staff (8) ------------------------------------------------------------------------
    { job: :adm, key: "ADM-01", name: "Kirana Puspita", gender: "Female", city: "Kota Tangerang",
      years: "2021 - present", role: "Administrative Assistant", employer: "PT Mandiri Konstruksi Jaya",
      line1: "Records incoming and outgoing letters in the document log and files them the same day",
      line2: "Prepares purchase orders and delivery notes in Excel for the project team",
      education: "Vocational High School (SMK) in Office Administration, SMK Bina Karya Tangerang, graduated 2020",
      skills: "Microsoft Excel and Word, Google Workspace, filing",
      hand: { "M1" => ["met", "Vocational High School (SMK) in Office Administration"], "S1" => ["3", "Records incoming and outgoing letters in the document log and files them the same day"],
              "S2" => ["3", "Microsoft Excel and Word"], "N1" => ["3", "Prepares purchase orders and delivery notes in Excel for the project team"] },
      state: :screened, step9: ["lanjut", 92, "ikut_ai", nil] },
    { job: :adm, key: "ADM-02", name: "Lukman Hakim", gender: "Male", city: "Kota Tangerang",
      years: "2022 - present", role: "Office Admin", employer: "Klinik Sehat Keluarga",
      line1: "Schedules appointments and keeps the patient document files in order",
      line2: "Prepares the weekly supply request in Excel",
      education: "Senior High School (SMA Negeri 7 Tangerang), graduated 2021",
      skills: "Microsoft Excel and Word, typing 60 wpm",
      hand: { "M1" => ["met", "Senior High School (SMA Negeri 7 Tangerang)"], "S1" => ["2", "Schedules appointments and keeps the patient document files in order"],
              "S2" => ["3", "Microsoft Excel and Word"], "N1" => ["0", ""] },
      state: :screened, step9: ["lanjut", 75, "lanjut", nil] },
    { job: :adm, key: "ADM-03", name: "Maya Anggraeni", gender: "Female", city: "Kabupaten Tangerang",
      years: "2023 - present", role: "Cashier", employer: "Minimarket Sumber Rezeki",
      line1: "Operates the cash register and counts the drawer at the end of each shift",
      line2: "Records daily sales totals in a notebook for the owner",
      education: "Senior High School (SMA Negeri 2 Balaraja), graduated 2022",
      skills: "Cash handling, customer service",
      hand: { "M1" => ["met", "Senior High School (SMA Negeri 2 Balaraja)"], "S1" => ["1", "Records daily sales totals in a notebook for the owner"],
              "S2" => ["0", ""], "N1" => ["0", ""] },
      state: :screened, step9: ["tidak_lanjut", 25, "ikut_ai", "No office administration or Excel experience in the CV; both are needed for the document log and the purchase orders."] },
    { job: :adm, key: "ADM-04", name: "Naufal Ramadhan", gender: "Male", city: "Kota Tangerang",
      years: "2020 - present", role: "Logistics Admin", employer: "PT Ekspedisi Lintas Jawa",
      line1: "Issues delivery notes and matches them with the drivers' proof of delivery",
      line2: "Maintains the shipment log in Excel and reports open items daily",
      education: "Diploma (D3) in Business Administration, Politeknik Tangerang Raya, graduated 2019",
      skills: "Microsoft Excel (VLOOKUP, pivot tables), Microsoft Word",
      hand: { "M1" => ["met", "Diploma (D3) in Business Administration"], "S1" => ["3", "Maintains the shipment log in Excel and reports open items daily"],
              "S2" => ["3", "Microsoft Excel (VLOOKUP, pivot tables), Microsoft Word"], "N1" => ["2", "Issues delivery notes and matches them with the drivers' proof of delivery"] },
      state: :screened, step9: ["lanjut", 89, nil, nil] },
    { job: :adm, key: "ADM-05", name: "Oktaviani Lestari", gender: "Female", city: "Kota Tangerang",
      years: "2019 - present", role: "Receptionist", employer: "Hotel Permata Tangerang",
      line1: "Handles guest check-in and the daily front-desk log",
      line2: "Types letters and memos for the front-office manager in Word",
      education: "Senior High School (SMA Negeri 5 Tangerang), graduated 2018",
      skills: "Microsoft Word, telephone etiquette, English conversation",
      hand: { "M1" => ["met", "Senior High School (SMA Negeri 5 Tangerang)"], "S1" => ["2", "Handles guest check-in and the daily front-desk log"],
              "S2" => ["2", "Microsoft Word"], "N1" => ["0", ""] },
      state: :screened, step9: nil },
    { job: :adm, key: "ADM-06", name: "Pandu Setiawan", gender: "Male", city: "Kota Tangerang",
      years: "2021 - present", role: "Data Entry Operator", employer: "PT Survei Data Nusantara",
      line1: "Enters survey forms into Excel sheets and checks totals against the paper forms",
      line2: "Prepares the weekly entry summary for the team leader",
      education: "Vocational High School (SMK) in Computer Networks, SMK Teknologi Tangerang, graduated 2020",
      skills: "Microsoft Excel (data entry, SUM, filters), Microsoft Word",
      hand: { "M1" => ["met", "Vocational High School (SMK) in Computer Networks"], "S1" => ["2", "Prepares the weekly entry summary for the team leader"],
              "S2" => ["3", "Microsoft Excel (data entry, SUM, filters), Microsoft Word"], "N1" => ["0", ""] },
      state: :held, step9: nil },
    { job: :adm, key: "ADM-07", name: "Qori Amalia", gender: "Female", city: "Kota Tangerang",
      years: "2018 - 2023", role: "Purchasing Admin", employer: "PT Mitra Pangan Sejati",
      line1: "Raises purchase orders in the ERP and follows up supplier confirmations",
      line2: "Files delivery notes against purchase orders for the monthly accrual list",
      education: "Diploma (D3) in Office Administration, Politeknik Tangerang Raya, graduated 2017",
      skills: "Microsoft Excel and Word, Odoo purchasing module",
      hand: { "M1" => ["met", "Diploma (D3) in Office Administration"], "S1" => ["3", "Files delivery notes against purchase orders for the monthly accrual list"],
              "S2" => ["3", "Microsoft Excel and Word"], "N1" => ["3", "Raises purchase orders in the ERP and follows up supplier confirmations"] },
      state: :screened, step9: ["lanjut", 90, "ikut_ai", nil] },
    { job: :adm, key: "ADM-08", name: "Rizky Firmansyah", gender: "Male", city: "Kota Tangerang",
      years: "2024 - present", role: "Intern", employer: "Tangerang City Notary Office",
      line1: "Scans and files deeds and prepares the daily list of documents received",
      line2: "Helps with typing cover letters in Word",
      education: "Currently in the final year of a Diploma (D3) in Office Administration, Politeknik Tangerang Raya",
      skills: "Microsoft Word, scanning and filing",
      hand: { "M1" => ["met", "Currently in the final year of a Diploma (D3) in Office Administration"], "S1" => ["1", "Scans and files deeds and prepares the daily list of documents received"],
              "S2" => ["1", "Microsoft Word"], "N1" => ["0", ""] },
      state: :screened, step9: nil },
    # ---- Area Supervisor (7) --------------------------------------------------------------------
    { job: :area, key: "ARE-01", name: "Satria Perdana", gender: "Male", city: "Kota Tangerang",
      years: "2018 - present", role: "Area Supervisor", employer: "PT Retail Prima Indonesia",
      line1: "Supervises nine convenience stores in Tangerang and Serang with two visits per store each month",
      line2: "Runs the monthly stock count and sends the weekly sales report to the regional manager",
      education: "Bachelor of Management, Universitas Cendana, graduated 2014",
      skills: "Driving licence A and C, Microsoft Excel (pivot tables), coaching store leaders",
      hand: { "M1" => ["met", "Driving licence A and C"], "S1" => ["3", "Supervises nine convenience stores in Tangerang and Serang with two visits per store each month"],
              "S2" => ["3", "Runs the monthly stock count and sends the weekly sales report to the regional manager"], "N1" => ["2", "coaching store leaders"] },
      state: :screened, step9: ["lanjut", 91, "ikut_ai", nil] },
    { job: :area, key: "ARE-02", name: "Tiara Maharani", gender: "Female", city: "Kota Tangerang",
      years: "2019 - present", role: "Store Manager", employer: "Apotek Sehat Sentosa",
      line1: "Manages one pharmacy outlet with six staff and the monthly stock count",
      line2: "Prepares the weekly sales and stock report for the owner",
      education: "Diploma (D3) in Pharmacy, Politeknik Kesehatan Banten, graduated 2016",
      skills: "Driving licence C, Microsoft Excel (basic formulas), stock counting",
      hand: { "M1" => ["met", "Driving licence C"], "S1" => ["1", "Manages one pharmacy outlet with six staff and the monthly stock count"],
              "S2" => ["3", "Prepares the weekly sales and stock report for the owner"], "N1" => ["0", ""] },
      state: :screened, step9: ["lanjut", 68, "lanjut", nil] },
    { job: :area, key: "ARE-03", name: "Umar Faruq", gender: "Male", city: "Kota Serang",
      years: "2016 - present", role: "Sales Representative", employer: "PT Distribusi Minuman Segar",
      line1: "Sells to forty traditional outlets across Serang on a weekly route",
      line2: "Records the daily sales figures in the company app",
      education: "Senior High School (SMA Negeri 1 Serang), graduated 2012",
      skills: "Driving licence A and C, route planning, Microsoft Excel (data entry)",
      hand: { "M1" => ["met", "Driving licence A and C"], "S1" => ["0", ""], "S2" => ["1", "Records the daily sales figures in the company app"], "N1" => ["0", ""] },
      state: :screened, step9: ["tidak_lanjut", 20, "ikut_ai", "Selling to outlets is not supervising them; no outlet supervision, stock count or coaching in the work history."] },
    { job: :area, key: "ARE-04", name: "Vania Oktaviani", gender: "Female", city: "Kota Tangerang Selatan",
      years: "2017 - present", role: "Assistant Area Manager", employer: "PT Kopi Nusantara Ritel",
      line1: "Supports the area manager across twelve coffee outlets and leads the monthly stock counts",
      line2: "Trains new outlet leaders on the opening and closing routines",
      education: "Bachelor of Business Administration, Universitas Mitra Bangsa, graduated 2016",
      skills: "Driving licence A, Microsoft Excel (pivot tables), training delivery",
      hand: { "M1" => ["met", "Driving licence A"], "S1" => ["2", "Supports the area manager across twelve coffee outlets and leads the monthly stock counts"],
              "S2" => ["2", "leads the monthly stock counts"], "N1" => ["3", "Trains new outlet leaders on the opening and closing routines"] },
      state: :screened, step9: ["lanjut", 72, nil, nil] },
    { job: :area, key: "ARE-05", name: "Wahyu Kurniawan", gender: "Male", city: "Kota Tangerang",
      years: "2020 - present", role: "Warehouse Supervisor", employer: "PT Logistik Cepat Banten",
      line1: "Supervises a team of eight in one distribution warehouse",
      line2: "Runs the weekly cycle count and reports stock differences to the manager",
      education: "Diploma (D3) in Logistics Management, Politeknik Tangerang Raya, graduated 2018",
      skills: "Driving licence A and C, WMS, Microsoft Excel (pivot tables)",
      hand: { "M1" => ["met", "Driving licence A and C"], "S1" => ["1", "Supervises a team of eight in one distribution warehouse"],
              "S2" => ["2", "Runs the weekly cycle count and reports stock differences to the manager"], "N1" => ["0", ""] },
      state: :screened, step9: nil },
    { job: :area, key: "ARE-06", name: "Xaverius Adi Nugroho", gender: "Male", city: "Kota Tangerang",
      years: "2015 - present", role: "Regional Operations Manager", employer: "PT Mode Busana Ritel",
      line1: "Leads thirty fashion outlets across Banten and West Jakarta through five area supervisors",
      line2: "Owns the monthly stock count programme and the weekly regional sales review",
      education: "Bachelor of Management, Universitas Cendana, graduated 2010",
      skills: "Driving licence A, Microsoft Excel and Power BI, coaching supervisors",
      hand: { "M1" => ["met", "Driving licence A"], "S1" => ["3", "Leads thirty fashion outlets across Banten and West Jakarta through five area supervisors"],
              "S2" => ["3", "Owns the monthly stock count programme and the weekly regional sales review"], "N1" => ["3", "coaching supervisors"] },
      state: :screened, step9: ["lanjut", 95, "tidak_lanjut", "Regional manager over five area supervisors; the vacancy is one of those roles. Band and scope do not fit; noted for a future regional opening."] },
    { job: :area, key: "ARE-07", name: "Yunita Sari", gender: "Female", city: "Kota Tangerang",
      years: "2021 - present", role: "Outlet Leader", employer: "Toko Roti Hangat",
      line1: "Runs one bakery outlet with four staff and the daily stock count",
      line2: "Sends the daily sales figure to the owner by message",
      education: "Senior High School (SMA Negeri 4 Tangerang), graduated 2019",
      skills: "Cash handling, stock counting",
      hand: { "M1" => ["not_met", ""], "S1" => ["0", ""], "S2" => ["1", "Runs one bakery outlet with four staff and the daily stock count"], "N1" => ["0", ""] },
      state: :screened, step9: nil }
  ].freeze

  # The planted fake quote for ACC-08 (step 7 scene): a sentence that is NOT in the CV, on the
  # must-have requirement. The evidence check marks it "unverified" and the result goes to the
  # reviewer instead of becoming a decision.
  PLANTED = { "ACC-08" => ["M1", "Bachelor of Accounting with honours, Universitas Terang"] }.freeze

  # The assessor names shown on the two Interview 1 links of ACC-01 (step 10). Invented.
  ASSESSORS = ["Finance Manager (first assessor)", "HR Manager (second assessor)"].freeze

  module_function

  # Runs the whole demo. hr: the HR Admin who decides (role hr_admin, three roles since 17 Oct 2026);
  # consultant: the vacancy's consultant; reviewer: the HR Manager who releases and is not the
  # consultant. Returns the three jobs.
  def run(hr:, consultant:, reviewer:, company: nil, now: Time.current)
    company ||= company!
    raise ArgumentError, "hr must have the hr_admin role (got #{hr.role})" unless hr.role == "hr_admin"
    raise ArgumentError, "reviewer must not be the consultant" if reviewer.id == consultant.id

    links = {}
    jobs = JOBS.map do |key, spec|
      # Two steps, so a run that stopped between them (a refused portal opening, a missing consent
      # text) finishes on the next run instead of leaving a vacancy without applicants behind:
      # the vacancy is created once; the portal is opened once; applicants go only into an empty S1.
      job = Job.find_by(title: spec[:title], client_company: company) || vacancy(key, spec, company:, hr:, consultant:, now:)
      Portal::WindowChange.open!(job:, actor: hr, now:) unless job.application_window_events.exists?
      unless job.stages.find_by!(code: "S1").participations.exists?
        ActiveRecord::Base.transaction do
          PEOPLE.select { |p| p[:job] == key }.each { |person| links[person[:key]] = applicant(job, person, consultant:, hr:, reviewer:, now:) }
        end
      end
      job
    end
    # The competency question bank (17 Oct 2026) on Admin Staff only: its apply link opens the
    # three-step form (details, CV, test); the other two vacancies keep the two-step form, so the
    # demo shows both. Built through the bank services (the consultant submits, the HR Manager
    # approves); idempotent.
    require_relative "demo_question_bank"
    admin_staff = jobs.find { |job| job.title == JOBS[:adm][:title] }
    DemoQuestionBank.seed!(job: admin_staff, admin: consultant, manager: reviewer) if admin_staff
    flagged_requirement!(admin_staff, hr:, now:) if admin_staff
    report(jobs, links)
    jobs
  end

  # The discrimination-check scene (the team lead, 18 Oct 2026): ONE requirement on Admin Staff that names
  # a protected attribute (age), added AFTER the portal opened and the applicants were screened, so
  # opening and screening are unchanged, and checked through Briefs::RequirementCheck like the brief
  # screen does. The rule pass flags it "replace" with the standard's reason; the seed has the AI off, so
  # the neutral wording the AI would propose is written here (invented). Nothing is applied: the line
  # stays open until a person decides it on the brief page. Not on Accounting Supervisor: an open line
  # turns that brief's "discrimination check" step back to not done, and the video films vacancy 1.
  # Idempotent: added once, by its text.
  FLAGGED_REQUIREMENT = { text: "Maximum age 30", evidence: "Date of birth in the CV",
                          replacement: "Can keep up with a high daily volume of documents and front-desk visitors" }.freeze

  def flagged_requirement!(job, hr:, now:)
    return if job.requirements.exists?(text: FLAGGED_REQUIREMENT[:text])

    job.requirements.create!(tier: "nilai_tambah", text: FLAGGED_REQUIREMENT[:text], cv_evidence: FLAGGED_REQUIREMENT[:evidence],
                             position: job.requirements.maximum(:position).to_i + 1)
    lines = Briefs::RequirementCheck.run!(job:, actor: hr, now:, record: false)
    doc = job.reload.requirement_check.deep_dup
    doc["lines"] = lines.map do |line|
      line["text"] == FLAGGED_REQUIREMENT[:text] && line["replacement"].to_s.empty? ? line.merge("replacement" => FLAGGED_REQUIREMENT[:replacement]) : line
    end
    job.update!(requirement_check: doc)
  end

  # TENANCY=single: exactly one client company exists. Created only on an empty install.
  def company!
    existing = ClientCompany.first
    return ClientCompany.create!(COMPANY) if existing.nil?

    unless existing.name == COMPANY[:name]
      puts "DemoGlassbox: the install's company is #{existing.name.inspect}, not #{COMPANY[:name].inspect} " \
           "(single tenant: one company only). Rename it in db/seeds.rb if the demo should show #{COMPANY[:name]}."
    end
    existing
  end

  # Step 3: the vacancy with its approved brief, locked stage parameters and the S1+S2 gate open.
  # Outside a transaction on purpose: Gates::Open checks a deferred constraint at commit time.
  # The applicant portal (step 4) is opened by `run`, at `now` and not back-dated: it needs a
  # consent text and a retention period in force (the main seed publishes both in development and
  # DEMO_MODE; a production install sets them on the settings page first), and the demo consent
  # text takes effect one day before the seed runs. A refusal there is the right outcome, not
  # something to rescue.
  # The job ad applicants read on /apply (17 Oct 2026: the seed approved the ads without a text, so the
  # public demo showed no description). Built from the brief, neutral words only, so the ad scan finds
  # nothing to flag.
  def ad_text(spec)
    duties = spec[:activities].map { |(description, _output, _share)| "- #{description}" }
    needs = spec[:requirements].map { |(_code, tier, text, _evidence, _weight)| "- #{text}#{' (an advantage)' if tier == 'nilai_tambah'}" }
    ["About this role", "PT Terang Nusantara is hiring a #{spec[:title]} in #{COMPANY[:city]}. #{spec[:success_90d]}", "",
     "What you will do", *duties, "", "What we look for", *needs, "",
     "How we select", "Every application is read against the same requirements. A person on our team decides every step, " \
                      "and you can follow your application with the status link we email you."].join("\n")
  end

  def vacancy(key, spec, company:, hr:, consultant:, now:)
    job = Job.create!(
      title: spec[:title], golongan: spec[:golongan], package: spec[:package], client_company: company,
      location: COMPANY[:city], placements: [COMPANY[:city]], headcount: spec[:headcount],
      employment_type: spec[:employment_type], work_arrangement: "onsite", relocation: "tidak_perlu",
      salary_min: spec[:salary].first, salary_max: spec[:salary].last, show_salary: true,
      success_90d: spec[:success_90d], consultant:, brief_status: "complete", brief_completed_at: now - 7.days,
      package_override_reason: spec[:package_override_reason],
      # The brief's own record of the stage weights and pass scores (Briefs::BriefCheck reads stage_plan),
      # the same figures as the stages created below. A complete brief must pass BriefCheck, or no brief
      # step can be saved again (17 Oct 2026: "Save & next does not work" on every Cup vacancy).
      stage_plan: { "S1" => { "weight" => 20, "threshold" => spec[:threshold] }, "S2" => { "weight" => 30, "threshold" => 60 },
                    "S3" => { "weight" => 20, "threshold" => 65 }, "S5" => { "weight" => 30, "threshold" => 70 } },
      ad_approved_at: now - 6.days, ad_approved_by_id: hr.id, ad_text: ad_text(spec), ad_flags: []
    )
    raise "#{spec[:title]}: salary floor #{job.salary_min} is below the 2026 minimum wage #{UMK_2026}" if job.salary_min < UMK_2026

    spec[:activities].each_with_index { |(d, o, s), i| job.activities.create!(position: i + 1, description: d, output: o, share_percent: s) }
    spec[:requirements].each_with_index do |(_code, tier, text, evidence, weight), i|
      job.requirements.create!(tier:, text:, cv_evidence: evidence, weight:, position: i + 1)
    end
    spec[:knockouts].each_with_index { |text, i| job.knockout_questions.create!(position: i + 1, text:) }
    spec[:competencies].each_with_index do |(stage, layer, name, a1, a3, a5, q), i|
      job.competencies.create!(position: i + 1, stage_code: stage, layer:, name:, anchor_1: a1, anchor_3: a3, anchor_5: a5, questions: q)
    end
    # Weights: CV rubric 20 / technical test 30 / Interview 1 20 / Interview 2 30. The S1 pass score
    # is the tier's (T2 65, T4 60), locked when the gate opens.
    s1 = job.stages.create!(code: "S1", score_source: "ai", weight: 20, threshold: spec[:threshold], gate: "screening")
    job.stages.create!(code: "S2", score_source: "manual_or_import", weight: 30, threshold: 60, gate: "screening")
    job.stages.create!(code: "S3", score_source: "scorecard", weight: 20, threshold: 65)
    job.stages.create!(code: "S5", score_source: "scorecard", weight: 30, threshold: 70)
    test_case(job, spec[:test_case], consultant:, hr:) if spec[:test_case]
    # The discrimination test (Appendix D) on the requirements, run for real: the seed has the AI off,
    # so this is the rule-table pass, and each line says the AI did not run (Briefs::DiscriminationCheck).
    Briefs::RequirementCheck.run!(job:, actor: hr, now: now - 7.days, record: false)
    Gates::Open.call(stage: s1, now: now - 5.days)
    job
  end

  # Step 5: the technical test, written through the same services as the screen (the consultant
  # saves the version, the HR owner approves it), so a case that breaks a rule fails loudly.
  # Called outside the applicants' transaction: the version-freeze trigger is deferred, and a
  # version saved, approved and started inside one enclosing transaction fails at commit.
  def test_case(job, spec, consultant:, hr:)
    params = { instructions: spec[:instructions], time_limit_minutes: spec[:time_limit_minutes].to_s,
               answer_types_submitted: "1", answer_types: %w[xlsx],
               case_file: SeedUpload.new(workbook(spec[:instructions], spec[:rows]), spec[:file]),
               criteria: spec[:criteria].each_with_index.to_h do |(activity, name, weight, a1, a3, a5), i|
                 [i.to_s, { activity_id: job.activities[activity].id.to_s, name:, weight: weight.to_s, anchor_1: a1, anchor_3: a3, anchor_5: a5 }]
               end }
    saved = TestCases::SaveVersion.call(job:, actor: consultant, params:)
    raise "#{job.title}: technical test refused: #{saved.errors.join(' | ')}" unless saved.ok?

    approved = TestCases::Approve.call(test_case: saved.test_case, actor: hr)
    raise "#{job.title}: technical test not approved: #{approved.errors.join(' | ')}" unless approved.ok?

    saved.test_case.reload
  end

  # A three-sheet workbook (instructions, data, answer) as the case file and the answers.
  def workbook(instructions, rows)
    package = Axlsx::Package.new
    book = package.workbook
    bold = book.styles.add_style(b: true)
    book.add_worksheet(name: "Instructions") do |sheet|
      sheet.add_row(["Case study (sample, invented data)"], style: bold)
      sheet.add_row([instructions])
    end
    book.add_worksheet(name: "Data") do |sheet|
      sheet.add_row(rows.first, style: bold)
      rows.drop(1).each { |row| sheet.add_row(row) }
    end
    book.add_worksheet(name: "Answer") { |sheet| sheet.add_row(["Row", "Correct figure", "Explanation"], style: bold) }
    package.to_stream.read
  end

  # Step 4 onwards for one invented applicant. Returns the status-link token (step 12).
  def applicant(job, person, consultant:, hr:, reviewer:, now:)
    applied = now - 4.days + PEOPLE.index(person).hours
    cv = cv_text(person)
    candidate = Candidate.create!(name: person[:name], email: email_of(person), phone: phone_of(person))
    consent = ConsentTemplate.in_force or raise "no consent text in force: publish one on the settings page first"
    application = JobApplication.create!(
      job:, candidate:, consent_at: applied, consent_template: consent,
      consent_retention_days: SystemSetting.retention_days || 30, created_at: applied, domicile_city: person[:city],
      cv_text: cv, cv_text_source: "pasted", cv_text_at: applied, cv_text_by_id: consultant.id
    )
    _link, token = OneTimeLink.issue!(subject: application, purpose: "candidate_status")
    stages = %w[S1 S2].to_h { |code| [code, job.stages.find_by!(code:)] }
    p1 = Participation.create!(job_application: application, stage: stages["S1"], attendance: "attended")
    p2 = Participation.create!(job_application: application, stage: stages["S2"], attendance: "pending")

    case person[:state]
    when :held then hold_for_release(p1, application, person, at: applied + 10.minutes)
    when :unverified then screen(job, p1, application, person, at: applied + 10.minutes, planted: PLANTED.fetch(person[:key]))
    else
      screen(job, p1, application, person, at: applied + 10.minutes)
      technical_test(job, application, p2, person, reviewer:, applied:, now:) if person[:test]
      decide_at_gate(job, p1, person, hr:, at: applied + 1.day) if person[:step9]
    end
    token
  end

  # Step 5 for one applicant: the attempt, the answer through TechnicalTests::SubmitAnswer (file
  # inspected like a real upload), and, when planned, the reviewer's score through
  # TechnicalTests::ScoreAnswer (ratings 1-5 per criterion, note required, S2 decision written).
  def technical_test(job, application, participation, person, reviewer:, applied:, now:)
    plan, ratings = person[:test]
    test_case = TechnicalTestCase.current_for(job) or raise "#{job.title}: no approved technical test"
    started = applied + 1.hour
    TestAttempt.create!(participation:, test_case:, started_at: started, due_at: started + test_case.time_limit_minutes.minutes)
    answer = SeedUpload.new(workbook("Answer sheet (sample, invented data).", [["Row", "Correct figure", "Explanation"], [2, 5_000_000, "Credit must equal the debit."]]), "answer.xlsx")
    attempt = TechnicalTests::SubmitAnswer.call(application:, file: answer, now: started + 31.minutes)
    return if plan == :answered

    by_id = test_case.criteria.sort_by(&:position).each_with_index.to_h { |c, i| [c.id.to_s, ratings.fetch(i).to_s] }
    TechnicalTests::ScoreAnswer.call(attempt:, reviewer:, ratings: by_id, note: "Sample data: scored against the three anchors.", now: now - 2.hours)
  end

  def cv_text(person)
    format(CV, name: person[:name], city: person[:city], dob: "12 March 1994", gender: person[:gender],
               house: 10 + PEOPLE.index(person), phone: phone_of(person), email: email_of(person),
               years: person[:years], role: person[:role], employer: person[:employer], line1: person[:line1],
               line2: person[:line2], education: person[:education], skills: person[:skills])
  end

  def email_of(person) = "#{person[:name].parameterize}@applicant.example"
  def phone_of(person) = format("0812-7%03d-%04d", PEOPLE.index(person) + 1, 1000 + PEOPLE.index(person))

  # Requirement code (M1, S1, S2, N1) => Screening::Rubric criterion, for one job.
  def criteria_by_code(job)
    spec = JOBS.fetch(JOBS.keys.find { |k| JOBS[k][:title] == job.title })
    rubric = Screening::Rubric.for(job)
    spec[:requirements].each_with_index.to_h do |(code, _tier, text, _ev, _w), _i|
      [code, rubric.criteria.find { |c| c.text == text } || raise("requirement #{code} not found on #{job.title}")]
    end
  end

  # Step 7: the AI row as Screening::Run would persist it, without the call. Each judgement is the
  # HAND judgement with its CV line as the quote; `verified` is the REAL evidence check on the
  # real CV text (Screening::QuoteCheck), so a typo in a quote above shows up as "unverified" in
  # the seeded demo rather than being hidden. `planted` replaces one quote with a fake one.
  def screen(job, participation, application, person, at:, planted: nil)
    rubric = Screening::Rubric.for(job)
    raise "#{job.title}: #{rubric.problems.join(' ')}" if rubric.problems.any?

    by_code = criteria_by_code(job)
    cv = application.cv_text
    judgements = by_code.to_h do |code, criterion|
      judgement, quote = person[:hand].fetch(code)
      quote = planted.last if planted && planted.first == code
      verified = Screening::QuoteCheck.verified?(judgement:, quote:, extracted: cv, redacted: cv)
      [criterion.key, { "judgement" => judgement, "quote" => quote, "verified" => verified }]
    end
    score = Screening::Score.compute(rubric, judgements)
    entry = ScoreEntry.create!(participation:, value: score.score, ratings: {}, entered_by_id: Screening::AI_ACTOR_ID,
                               event_at: application.created_at, entered_at: at, model_id: MODEL_ID,
                               prompt_version: Screening::PROMPT_VERSION)
    check = ->(q) { Screening::QuoteCheck.verified?(judgement: "met", quote: q, extracted: cv, redacted: cv) }
    claim = ->(text, q) { { "claim" => text, "quote" => q, "verified" => check.(q) } }
    role_line = "#{person[:years]}  #{person[:role]} at #{person[:employer]}, #{person[:city]}"
    ScreeningResult.create!(
      participation:, score_entry: entry, rubric_digest: rubric.digest, model_id: MODEL_ID, prompt_version: Screening::PROMPT_VERSION,
      judgements: rubric.criteria.map do |c|
        { "requirement_id" => c.requirement_id, "key" => c.key, "tier" => c.tier, "text" => c.text, "weight" => c.weight }.merge(judgements.fetch(c.key))
      end,
      score: score.score, wajib_met: score.wajib_met, unverified_count: score.unverified_count, bonus_points: score.bonus_points,
      bonus_possible: score.bonus_possible, created_at: at,
      last_position: { "text" => "#{person[:role]}, #{person[:employer]}", "quote" => role_line, "verified" => check.(role_line) },
      education: { "text" => person[:education], "quote" => person[:education], "verified" => check.(person[:education]) },
      recent_experience: { "text" => "#{person[:line1]}.", "quote" => person[:line1], "verified" => check.(person[:line1]) },
      narratives: {
        "strengths" => [claim.("Sample data: the strongest evidence line for this role.", person[:line1])],
        "blind_spots" => [claim.("Sample data: what the CV does not show yet.", "")],
        "tolerance_risks" => [claim.("Sample data: a point to explore at interview.", person[:line2])],
        "credibility_value" => [claim.("Sample data: the skills line.", person[:skills])]
      },
      label_proposal: label_for(score), label_reason: "Sample data: a real vacancy carries the AI's written reason here."
    )
    participation.update!(screening_state: "done", screening_state_at: at)
    # An unverified result never becomes a decision by itself: it waits in the review queue for a
    # person (Screening::Finalize writes nothing for it). Only clean results get the rule decision.
    return if score.unverified_count.positive?

    outcome = Screening::Score.outcome(wajib_met: score.wajib_met, score: score.score, threshold: participation.stage.threshold)
    Decision.create!(participation:, outcome: outcome.outcome.to_s, basis: outcome.basis.to_s, reason_code: outcome.reason_code, decided_at: at)
  end

  def label_for(score)
    return "tidak_relevan" unless score.wajib_met
    return "direkomendasikan" if score.score >= 80
    return "pertimbangkan" if score.score >= 65
    return "pertimbangkan_terbatas" if score.score >= 50

    "tidak_prioritas"
  end

  # Step 6: the CV stops at "Awaiting review". The release row is prepared exactly as
  # Screening::ReleaseGate#create_release prepares it (evidence sections, then the redactor with
  # the applicant's own name), and NOTHING is sent. Written here rather than through the gate
  # because the gate's prepare step is private and its automatic mode would try to send.
  def hold_for_release(participation, application, person, at:)
    job = participation.stage.job
    rubric = Screening::Rubric.for(job)
    evidence = Screening::EvidenceSections.keep(application.cv_text, groups: Screening::CvSections.enabled(company: job.client_company))
    raise "#{person[:key]}: no evidence section found in the CV" if evidence.nil?

    redacted = Screening::Redactor.call(evidence, names: [person[:name]]).text
    payload = Screening::AiClient.user_content(redacted, rubric.payload)
    prefix = Screening::AiClient.user_content("\u0000", rubric.payload).split("\u0000").first
    start = prefix.count("\n")
    AiRelease.create!(
      participation:, job:, payload_kind: Screening::ReleaseGate::KIND, payload_text: payload,
      payload_sha256: AiRelease.digest(payload), cv_line_start: start, cv_line_end: start + redacted.split("\n", -1).size - 1,
      rubric_digest: rubric.digest, source_sha256: AiRelease.digest(application.cv_text),
      residual_categories: Screening::ResidualCheck.findings(redacted, names: [person[:name]]), created_at: at
    )
    participation.update!(screening_state: "awaiting_release", screening_state_at: at)
  end

  # Step 9: the AI advice row beside the HR owner's choice, through the real Progression::Choose,
  # so every rule applies (a note on every "do not continue", a note when departing from the
  # advice). choice nil = advice shown, the person has not chosen yet (choose it live).
  def decide_at_gate(job, participation, person, hr:, at:)
    advice, ai_score, choice, note = person[:step9]
    recommendation = StageRecommendation.create!(
      participation:, requested_by: hr, status: "ready", advice:, ai_score:, model_id: MODEL_ID,
      prompt_version: Progression::Recommend::PROMPT_VERSION, created_at: at,
      summary: advice == "lanjut" ? "Sample data: the CV evidence for this stage is strong enough to continue." : "Sample data: the CV evidence for this stage is not enough.",
      reasons: { "strengths" => ["Sample data: #{person[:line1]}"], "gaps" => ["Sample data: what the next stage should test"],
                 "risks" => [], "change_view" => "Sample data: the next stage's result." }
    )
    return if choice.nil?

    Progression::Choose.call(participation:, actor: hr, choice:, note:, now: at + 1.hour, seen_recommendation_id: recommendation.id)
    interview(job, participation, hr:, at: at + 2.days) if person[:interview]
  end

  # Step 10: Interview 1 (S3) with two assessor links. The first assessor has scored; the second
  # link is still open so the demo can score it live from a phone. Scores stay hidden from each
  # other until both are in (the app's rule, not this seed's).
  def interview(job, gate_participation, hr:, at:)
    s3 = job.stages.find_by!(code: "S3")
    participation = gate_participation.job_application.participations.find_by(stage: s3) ||
                    Participation.create!(job_application: gate_participation.job_application, stage: s3, attendance: "pending")
    Progression.open_stage!(s3, at)
    first, _t1 = Progression::InviteInterviewer.call(participation:, actor: hr, name: ASSESSORS[0], now: at)
    _second, token = Progression::InviteInterviewer.call(participation:, actor: hr, name: ASSESSORS[1], now: at + 1.minute)
    participation.update!(attendance: "attended")
    ratings = job.competencies.where(stage_code: "S3").to_h { |c| [c.id.to_s, 4] }
    entry = ScoreEntry.create!(participation:, value: Scoring::StageScore.from_ratings(ratings.values), ratings:,
                               note: "Sample data: explained the monthly close step by step; reported a cash difference once and traced it.",
                               entered_by_id: hr.id, event_at: at + 2.hours, entered_at: at + 2.hours)
    first.update!(score_entry: entry, submitted_at: entry.entered_at)
    @interview_token = token
  end

  # Paths come from the route helpers, so a renamed slug (A4) never leaves a stale path here.
  def report(jobs, links)
    routes = Rails.application.routes.url_helpers
    jobs.each { |job| puts "GlassBox demo: #{job.title} (#{routes.lamar_path(job.public_code)}, /staff/jobs/#{job.id})" }
    first = PEOPLE.first
    puts "GlassBox demo: applicant status link for #{first[:key]}: #{routes.candidate_status_path(links[first[:key]])}" if links[first[:key]]
    puts "GlassBox demo: second assessor link (Interview 1, #{first[:key]}): #{routes.interviewer_score_path(@interview_token)}" if @interview_token
  end

  # docs/evaluation/hand-scores.csv, generated from HAND so the file and the seed agree. One row per
  # applicant per requirement; n = PEOPLE.size applicants, PEOPLE.size * 4 rows. The planted fake
  # quote is NOT a hand score and is not in this file. Written without the csv gem (not in the
  # Gemfile; Ruby 4 no longer bundles it): every field is double-quoted, quotes doubled, RFC 4180.
  # The tier column carries the brief's English words (GLOSSARY-EN.md); the stored enum values
  # (wajib / sebaiknya / nilai_tambah) never change and stay inside the database.
  TIER_WORDS = { "wajib" => "must", "sebaiknya" => "should", "nilai_tambah" => "nice" }.freeze

  def hand_scores_csv
    rows = [%w[cv_id vacancy tier requirement_code requirement hand_judgement hand_quote]]
    PEOPLE.each do |person|
      spec = JOBS.fetch(person[:job])
      spec[:requirements].each do |code, tier, text, _evidence, _weight|
        judgement, quote = person[:hand].fetch(code)
        rows << [person[:key], spec[:title], TIER_WORDS.fetch(tier), code, text, judgement, quote]
      end
    end
    rows.map { |row| row.map { |field| %("#{field.to_s.gsub('"', '""')}") }.join(",") + "\n" }.join
  end
end
