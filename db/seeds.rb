# Demo data for development. Every name, company and address here is INVENTED (brief §2: no
# real candidate or client data). The retention period is deliberately NOT seeded (D32): an
# admin sets it on Pengaturan Sistem, and until then the portal cannot open.
password = "glassbox-demo-2026"

# Seeding never sends anything to the AI, whatever .env says: the demo rows are written as "data
# contoh", and the release demo shows a CV waiting for a reviewer. Put back at the end of the file.
ai_config = Screening::Config.singleton_class
ai_saved = %i[enabled? review_before_ai?].to_h { |name| [ name, Screening::Config.method(name) ] }
ai_config.define_method(:enabled?) { false }
ai_config.define_method(:review_before_ai?) { true }

# The demo company (A6, 16 Oct 2026): PT Terang Nusantara, Kota Tangerang (invented; the city is real
# so the Gate 0 minimum wage can cite a real decree). TENANCY=single allows one company, so the Cup
# seed (db/seeds/demo_glassbox.rb) uses this row.
company = ClientCompany.first || ClientCompany.create!(
  name: "PT Terang Nusantara", address: "Jl. Industri Terang Blok C No. 21", city: "Kota Tangerang",
  contact_email: "hr@terangnusantara.example"
)

# One account per role; the demo door (/demo) picks the first user of a role. README lists them.
{
  # Three roles (17 Oct 2026). The HR Admin prepares and decides and is the vacancies' consultant;
  # the HR Manager releases CVs to Gemini, scores the test and agrees the salary. Two people, so the
  # rule "the reviewer is never the vacancy's consultant" holds. The superadmin passes every check.
  "hr@terangnusantara.example" => [ "Dewi Lestari", "hr_admin", company ],
  "manager@terangnusantara.example" => [ "Hendra Wijaya", "hr_manager", company ],
  "admin@glassbox.example" => [ "GlassBox Superadmin", "superadmin", nil ]
}.each do |email, (name, role, client_company)|
  User.find_or_create_by!(email_address: email) do |user|
    user.name = name
    user.role = role
    user.client_company = client_company
    user.password = password
  end
end

# The demo applications record the consent text the candidate agreed to, so a fresh database needs
# one in force. Invented demo wording, clearly marked; a real install publishes its own text on
# Pengaturan Sistem. English only (AI Builder Cup rule), and never the literal "[PLACEHOLDER": that
# prefix keeps the portal closed (ConsentTemplate#placeholder_sections, Portal::ConsentReadiness).
ConsentTemplate.in_force || ConsentTemplate.create!(
  ConsentTemplate::SECTIONS.to_h do |field, heading|
    [ field, "[DEMO TEXT, not legal text] Sample wording for the demo (#{heading}). A real install publishes the employer's own text." ]
  end.merge(version: "demo-1", effective_from: 1.day.ago, created_at: Time.current)
)
# demo-2 (18 Oct 2026): the demo text plus the AI interview addendum, so the AI interview runs only
# under a consent text that names it (ConsentTemplate#names_ai_interview?, UU PDP Pasal 21). A new
# version, never an edit: applicants who agreed to demo-1 keep demo-1.
if (base = ConsentTemplate.in_force) && !base.names_ai_interview?
  ConsentTemplate.create!(base.with_ai_interview_addendum.merge(version: "demo-2", effective_from: 1.minute.ago, created_at: Time.current))
end

puts "Seeded #{company.name}: users #{User.count}. Password: #{password}"

# The Cup demo data (A6): three English vacancies for PT Terang Nusantara with 25 invented applicants
# at every step of the twelve, the planted fake quote for the evidence check, and the hand scores in
# docs/evaluation/hand-scores.csv. Idempotent. This is the ONLY demo data the public demo carries.
require_relative "seeds/demo_glassbox"
glassbox_hr = User.find_by!(email_address: "hr@terangnusantara.example")
glassbox_consultant = glassbox_hr # the HR Admin is the vacancies' consultant (three roles)
glassbox_reviewer = User.find_by!(email_address: "manager@terangnusantara.example")

# Development only: a demo consent text and retention period, so a FRESH development database can
# run the demo seeds below (several of them submit applications, which the portal refuses without a
# consent text in force, D38). Production keeps D32: an admin sets retention and publishes a real
# consent text on the settings page; this block never runs there. In DEMO_MODE=1 (the Cup
# deployment, A5) it runs too: the demo portal must accept applications without an admin's hand.
# Every section is marked as demo text so nobody mistakes it for legal text. Idempotent: it does
# nothing when any consent version or retention value already exists.
if Rails.env.development? || Glassbox::Settings.demo_mode?
  admin = User.find_by!(email_address: "admin@glassbox.example")
  if ConsentTemplate.none?
    demo_line = "[DEMO TEXT, not legal text] The employer's legal team writes this section."
    ConsentTemplate.create!(
      ConsentTemplate::SECTIONS.keys.index_with { demo_line }.merge(
        purpose: "[DEMO TEXT] Your data is used only for this recruitment process.",
        version: "demo-2026-10-10", effective_from: 1.day.ago
      )
    )
  end
  Portal::UpdateSetting.call(key: "retention_days", value: "30", actor: admin) if SystemSetting.retention_days.nil?
  puts "Demo consent (development only): version #{ConsentTemplate.in_force&.version}, retention #{SystemSetting.retention_days} days"
end

# The public demo (DEMO_MODE=1) runs the AI interview (Vida, 18 Oct 2026): the settings page is not
# routed there, so the seed switches it on (install-wide on a single-tenant install, per company on a
# multi-tenant one: Glassbox::Settings.settings_company_id). Portal::UpdateSetting refuses unless
# the consent text in force names the interview (demo-2 above), so the guard holds here too. It still
# needs an AI provider and the automatic review mode (Interviews.enabled_for?).
if Glassbox::Settings.demo_mode? && !SystemSetting.ai_interview?(company:)
  Portal::UpdateSetting.call(key: "ai_interview", value: "1", actor: glassbox_hr)
end

glassbox_jobs = DemoGlassbox.run(hr: glassbox_hr, consultant: glassbox_consultant, reviewer: glassbox_reviewer, company:)
puts "Demo Cup data (A6): #{glassbox_jobs.map { |j| "#{j.title} (/apply/#{j.public_code})" }.join('; ')}"

# The earlier feature demos (jobs, technical test, screening report, Google, review before AI, the
# first Cup walk-through), translated to English on 17 Oct 2026 like every demo record. They stay
# available for development behind LEGACY_DEMO_SEEDS=1 and never run on the public demo, so the demo
# workspace shows only the Cup data above. Their seed tests load the modules directly and do not
# depend on this switch.
if Glassbox::Settings.legacy_demo_seeds?
# The first feature demo job, development only (English title and knockout questions, 17 Oct 2026).
job = Job.find_or_create_by!(title: "Warehouse Admin Staff", client_company: company) do |j|
  j.golongan = 2
  j.location = "Bekasi"
  j.salary_min = 5_200_000
  j.salary_max = 6_000_000
  j.show_salary = true
end

if job.knockout_questions.none?
  job.knockout_questions.create!(position: 1, text: "Are you willing to work shifts in Bekasi?")
  job.knockout_questions.create!(position: 2, text: "Do you have at least 1 year of administrative experience?")
end

if job.stages.none?
  [ [ "S1", "ai", 10, 60 ], [ "S2", "manual_or_import", 20, 60 ], [ "S3", "scorecard", 20, 65 ],
   [ "S5", "scorecard", 50, 70 ] ].each do |code, source, weight, threshold|
    job.stages.create!(code:, score_source: source, weight:, threshold:)
  end
end

puts "Legacy demo job: #{job.title} (/apply/#{job.public_code})"
# Feature 03: six sample jobs on the house Golongan template (D49). Invented demo content; see the
# header of db/seeds/demo_jobs.rb. Written through the brief services as the HR PIC, so every
# brief is checked and every save is recorded like a real one.
require_relative "seeds/demo_jobs"
hr_user = glassbox_hr
demo_jobs = DemoJobs.run(company:, actor: hr_user)
puts "Demo jobs (feature 03): #{demo_jobs.map { |j| "#{j.title} G#{j.golongan} P#{j.package} #{j.brief_status}" }.join('; ')}"

# Feature 07 slices 3-5 (D60; GlassBox Team D52): every technical-test state on two invented demo jobs. See
# the header of db/seeds/demo_technical_test.rb. Idempotent.
require_relative "seeds/demo_technical_test"
demo_tests = DemoTechnicalTest.run(company:, hr: hr_user, consultant: glassbox_consultant,
                                   reviewer: glassbox_reviewer)
puts "Demo technical test (feature 07): #{demo_tests.map { |j| "#{j.title} ##{j.id}" }.join('; ')}"

# Feature 08: "Laporan Analisis Kandidat" demo (D61/D62, D52 "seeder untuk data contohnya semua").
# Two invented jobs (gate open = names hidden for HR PIC/owner; gate closed = names shown), nine
# invented candidates covering every label, gate result, salary fit and test state. Idempotent.
require_relative "seeds/demo_screening_report"
report_jobs = DemoScreeningReport.run(company:, hr: hr_user, consultant: glassbox_consultant,
                                      reviewer: glassbox_reviewer)
puts "Screening report demo (feature 08): #{report_jobs.map { |j| "#{j.title} (/staff/jobs/#{j.id}/screening-report)" }.join('; ')}"

# Feature 10: Google integrations demo (D52). Invented rows only, no credential, no Google call;
# shows a sent and a failed calendar invite, a failed Gmail delivery and the health rows.
require_relative "seeds/demo_google"
google_lines = DemoGoogle.run(consultant: glassbox_consultant,
                              admin: User.find_by!(email_address: "admin@glassbox.example"))
puts "Demo Google (feature 10): #{google_lines.join('; ')}"

# Feature 09: "Pemeriksaan sebelum AI" demo (D51 B, D52). One invented job, five invented CVs in
# the five release states (clean, residual findings, no evidence section, released, not sent).
# Idempotent: skipped when the job exists.
require_relative "seeds/demo_ai_release"
release_job = DemoAiRelease.run(company:, consultant: glassbox_consultant,
                                reviewer: glassbox_reviewer)
puts "Review before AI demo (feature 09): #{release_job.title} (/staff/jobs/#{release_job.id}/ai-review)"

# AI Builder Cup: one invented job walked through the nine steps (candidates at every point, the
# user's interview link for Kandidat C still waiting), so the demo and Ringkasan Dampak have data.
# See the header of db/seeds/demo_cup.rb. Idempotent: skipped when the job exists.
require_relative "seeds/demo_cup"
cup_job = DemoCup.run(company:, hr: hr_user, consultant: glassbox_consultant,
                      reviewer: glassbox_reviewer,
                      owner: glassbox_reviewer)
puts "Demo Cup: #{cup_job.title} (/staff/jobs/#{cup_job.id}, /staff/impact)"
end

ai_saved.each { |name, original| ai_config.define_method(name, original) }
