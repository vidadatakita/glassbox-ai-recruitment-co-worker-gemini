# Demo data for development. Every name, company and address here is INVENTED (brief §2: no
# real candidate or client data). The retention period is deliberately NOT seeded (D32): an
# admin sets it on Pengaturan Sistem, and until then the portal cannot open.
password = "glassbox-demo-2026"

# Seeding never sends anything to the AI, whatever .env says: the demo rows are written as "data
# contoh", and the release demo shows a CV waiting for a reviewer. Put back at the end of the file.
ai_config = Screening::Config.singleton_class
ai_saved = %i[enabled? review_before_ai?].to_h { |name| [name, Screening::Config.method(name)] }
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
  "hr@terangnusantara.example" => ["Dewi Lestari", "hr_pic", company],
  "consultant@glassbox.example" => ["Rangga Saputra", "consultant", nil],
  "reviewer@glassbox.example" => ["Sari Wulandari", "reviewer", nil],
  "admin@terangnusantara.example" => ["System Admin", "admin", company],
  # The owner agrees the salary (step 11); the AI never sees money.
  "owner@terangnusantara.example" => ["Hendra Wijaya", "owner", company]
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
# Pengaturan Sistem.
ConsentTemplate.in_force || ConsentTemplate.create!(
  ConsentTemplate::SECTIONS.keys.to_h { |field| [field, "Teks contoh untuk demo, bukan teks hukum (#{ConsentTemplate::SECTIONS[field]})."] }
    .merge(version: "demo-1", effective_from: 1.day.ago, created_at: Time.current)
)

puts "Seeded #{company.name}: users #{User.count}. Password: #{password}"

# The Cup demo data (A6): three English vacancies for PT Terang Nusantara with 25 invented applicants
# at every step of the twelve, the planted fake quote for the evidence check, and the hand scores in
# docs/evaluation/hand-scores.csv. Idempotent. This is the ONLY demo data the public demo carries.
require_relative "seeds/demo_glassbox"
glassbox_hr = User.find_by!(email_address: "hr@terangnusantara.example")
glassbox_consultant = User.find_by!(email_address: "consultant@glassbox.example")
glassbox_reviewer = User.find_by!(email_address: "reviewer@glassbox.example")

# Development only: a demo consent text and retention period, so a FRESH development database can
# run the demo seeds below (several of them submit applications, which the portal refuses without a
# consent text in force, D38). Production keeps D32: an admin sets retention and publishes a real
# consent text on the settings page; this block never runs there. In DEMO_MODE=1 (the Cup
# deployment, A5) it runs too: the demo portal must accept applications without an admin's hand.
# Every section is marked as demo text so nobody mistakes it for legal text. Idempotent: it does
# nothing when any consent version or retention value already exists.
if Rails.env.development? || Glassbox::Settings.demo_mode?
  admin = User.find_by!(email_address: "admin@terangnusantara.example")
  if ConsentTemplate.none?
    demo_line = "[CONTOH DEMO, bukan teks hukum] Isi bagian ini ditulis oleh legal klien."
    ConsentTemplate.create!(
      ConsentTemplate::SECTIONS.keys.index_with { demo_line }.merge(
        purpose: "[CONTOH DEMO] Data Anda dipakai hanya untuk proses rekrutmen ini.",
        version: "demo-2026-10-10", effective_from: 1.day.ago
      )
    )
  end
  Portal::UpdateSetting.call(key: "retention_days", value: "30", actor: admin) if SystemSetting.retention_days.nil?
  puts "Demo consent (development only): version #{ConsentTemplate.in_force&.version}, retention #{SystemSetting.retention_days} days"
end

glassbox_jobs = DemoGlassbox.run(hr: glassbox_hr, consultant: glassbox_consultant, reviewer: glassbox_reviewer, company:)
puts "Demo Cup data (A6): #{glassbox_jobs.map { |j| "#{j.title} (/apply/#{j.public_code})" }.join('; ')}"

# The earlier feature demos (jobs, technical test, screening report, Google, review before AI, the
# first Cup walk-through) carry Indonesian titles and text. They stay available for development
# behind LEGACY_DEMO_SEEDS=1 and never run on the public demo, so the demo workspace shows only the
# English Cup data above. Their seed tests load the modules directly and do not depend on this switch.
if Glassbox::Settings.legacy_demo_seeds?
# The first feature demo job (Indonesian title and knockout questions), development only.
job = Job.find_or_create_by!(title: "Staf Admin Gudang", client_company: company) do |j|
  j.golongan = 2
  j.location = "Bekasi"
  j.salary_min = 5_200_000
  j.salary_max = 6_000_000
  j.show_salary = true
end

if job.knockout_questions.none?
  job.knockout_questions.create!(position: 1, text: "Bersedia bekerja shift di Bekasi?")
  job.knockout_questions.create!(position: 2, text: "Memiliki pengalaman administrasi minimal 1 tahun?")
end

if job.stages.none?
  [["S1", "ai", 10, 60], ["S2", "manual_or_import", 20, 60], ["S3", "scorecard", 20, 65],
   ["S5", "scorecard", 50, 70]].each do |code, source, weight, threshold|
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
puts "Demo laporan (feature 08): #{report_jobs.map { |j| "#{j.title} (/staff/jobs/#{j.id}/laporan-analisis)" }.join('; ')}"

# Feature 10: Google integrations demo (D52). Invented rows only, no credential, no Google call;
# shows a sent and a failed calendar invite, a failed Gmail delivery and the health rows.
require_relative "seeds/demo_google"
google_lines = DemoGoogle.run(consultant: glassbox_consultant,
                              admin: User.find_by!(email_address: "admin@terangnusantara.example"))
puts "Demo Google (feature 10): #{google_lines.join('; ')}"

# Feature 09: "Pemeriksaan sebelum AI" demo (D51 B, D52). One invented job, five invented CVs in
# the five release states (clean, residual findings, no evidence section, released, not sent).
# Idempotent: skipped when the job exists.
require_relative "seeds/demo_ai_release"
release_job = DemoAiRelease.run(company:, consultant: glassbox_consultant,
                                reviewer: glassbox_reviewer)
puts "Demo pemeriksaan sebelum AI (feature 09): #{release_job.title} (/staff/jobs/#{release_job.id}/pemeriksaan-ai)"

# AI Builder Cup: one invented job walked through the nine steps (candidates at every point, the
# user's interview link for Kandidat C still waiting), so the demo and Ringkasan Dampak have data.
# See the header of db/seeds/demo_cup.rb. Idempotent: skipped when the job exists.
require_relative "seeds/demo_cup"
cup_job = DemoCup.run(company:, hr: hr_user, consultant: glassbox_consultant,
                      reviewer: glassbox_reviewer,
                      owner: User.find_by!(email_address: "owner@terangnusantara.example"))
puts "Demo Cup: #{cup_job.title} (/staff/jobs/#{cup_job.id}, /staff/dampak)"
end

ai_saved.each { |name, original| ai_config.define_method(name, original) }
