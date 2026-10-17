# Demo competency test bank (17 Oct 2026, feature 01/02): one approved bank on the Admin Staff
# vacancy, so the three-step application (details -> CV -> competency test) can be shown. Built through
# the same services as the screen: the HR Admin adds and submits, the HR Manager approves. Invented,
# English content. Idempotent: does nothing when the vacancy already has a bank.
module DemoQuestionBank
  TECHNICAL = [
    ["An invoice shows 12 boxes at Rp45.000 each and a total of Rp560.000. What do you do?", %w[Pay\ Rp560.000 Correct\ the\ total\ to\ Rp540.000\ and\ ask\ the\ supplier\ for\ a\ new\ invoice Pay\ half\ now Ignore\ the\ difference], 1],
    ["A file named '2026-10 Purchase orders' must be found by anyone in the team. Where does it belong?", ["Your own desktop", "The shared folder for October 2026 purchase orders", "An e-mail to yourself", "A USB stick"], 1],
    ["Three requests arrive at once: a manager's report due in one hour, a supplier asking for a callback, and filing. Which first?", ["Filing", "The supplier callback", "The report due in one hour", "Whichever came last"], 2],
    ["A spreadsheet row total reads Rp1.250.000 but the items add up to Rp1.205.000. What is the most likely cause?", ["Two digits swapped when typing", "The computer is broken", "Tax was added twice", "Nothing; small differences are normal"], 0],
    ["Which date format avoids confusion in a shared list?", ["10/11/26", "2026-11-10", "Nov 10", "10-11"], 1],
    ["A visitor asks for an employee's home address. What do you do?", ["Give it", "Refuse politely and offer to pass on a message", "Give only the city", "Ask a colleague to give it"], 1],
    ["You must order paper: 4 boxes are used per week, 6 are left, delivery takes 2 weeks. When do you order?", ["Next month", "Today", "When the last box is opened", "In two weeks"], 1],
    ["Meeting minutes should record at least:", ["Who said what, word for word", "Decisions, owners and due dates", "Only the date", "The menu"], 1]
  ].freeze
  TECHNICAL_WRITTEN = [
    "A supplier's delivery note lists 50 items, but only 45 arrived. Describe what you record and who you inform.",
    "Your manager asks for a weekly summary of incoming letters. Describe how you would set it up."
  ].freeze
  ROLE = [
    ["A colleague keeps asking you to do their filing. What is the best first step?", ["Do it quietly", "Talk to them about priorities and involve the supervisor if it continues", "Refuse rudely", "Complain to others"], 1],
    ["You made an error in a report already sent. What do you do?", ["Wait and hope", "Tell the recipient, send a corrected version and note the cause", "Blame the system", "Delete the e-mail"], 1],
    ["Two managers give you conflicting deadlines. What do you do?", ["Pick the friendlier one", "Ask both to agree the order, or ask your supervisor", "Do neither", "Do both badly"], 1],
    ["A new tool would save the team time but you are unsure how it works. What do you do?", ["Avoid it", "Try it on a small task and ask for a short demo", "Wait for someone else", "Tell others it is bad"], 1]
  ].freeze
  ROLE_WRITTEN = [
    "Describe a time you had to finish a task with unclear instructions. What did you do?",
    "A customer is angry on the phone about a late document. Describe what you say and do."
  ].freeze

  def self.seed!(job:, admin:, manager:)
    return if QuestionBank.exists?(job_id: job.id)

    activities = job.activities.to_a
    competencies = job.competencies.to_a
    return if activities.empty? || competencies.empty?

    add = lambda do |params|
      result = TestCases::SaveBank.call(job:, actor: admin, action: "add", params:)
      raise "demo bank question refused: #{result.errors.join('; ')}" unless result.ok?
    end
    anchors = { anchor_1: "Misses the main point or gives no concrete step", anchor_3: "Gives the right steps in a sensible order",
                anchor_5: "Gives the right steps, who is informed and how it is recorded, with a check afterwards" }
    TECHNICAL.each_with_index do |(prompt, options, correct), i|
      add.call(section: "technical", kind: "multiple_choice", link_id: "a:#{activities[i % activities.size].id}", prompt:,
               options: options.each_with_index.to_h { |o, k| [k.to_s, o] }, correct: correct.to_s)
    end
    TECHNICAL_WRITTEN.each_with_index do |prompt, i|
      add.call(section: "technical", kind: "written", link_id: "a:#{activities[(i + 3) % activities.size].id}", prompt:, **anchors)
    end
    ROLE.each_with_index do |(prompt, options, correct), i|
      add.call(section: "role", kind: "multiple_choice", link_id: "c:#{competencies[i % competencies.size].id}", prompt:,
               options: options.each_with_index.to_h { |o, k| [k.to_s, o] }, correct: correct.to_s)
    end
    ROLE_WRITTEN.each_with_index do |prompt, i|
      add.call(section: "role", kind: "written", link_id: "c:#{competencies[(i + 1) % competencies.size].id}", prompt:, **anchors)
    end
    bank = QuestionBank.latest_for(job)
    [[admin, "submit"], [manager, "approve"]].each do |actor, action|
      result = TestCases::BankDecision.call(bank: bank.reload, actor:, action:)
      raise "demo bank #{action} refused: #{result.errors.join('; ')}" unless result.ok?
    end
    bank
  end
end
