# AiCoHire by GlassBox: AI Recruitment Co-worker

**Evidence you can see. Decisions someone owns. Merit that counts.**

Team GlassBox's entry for the Google Cloud AI Builder Cup 2026, theme *Future of Work & Enterprise Productivity*.
Gemini on Vertex AI proposes; a named person decides at every step; every score cites a verbatim quote from the
CV; sensitive data is removed before any model call; every applicant always sees their stage and next date.

**Status: prototype in build (deadline 18 Oct 2026).** All data in this project is invented.

## Documentation (`docs/`)

| File | What it is |
|---|---|
| `docs/GLASSBOX-PLAN.md` | Project plan: origin of the code, merit analysis, task list A1–A11, project rules, team decisions |
| `docs/FLOW-v2.1-glassbox.md` | The 12-step prototype flow, the three checks, roadmap, verified evidence (§5.1), team decision log (§7) |
| `docs/BUILD-PLAN-18-OCT.md` | Timeline 16–18 Oct, proposed owners, submission gates, cut order |
| `docs/video-material/` | Everything for the video: `VIDEO-NARRATION-aicohire.md` (the 3-minute script for three presenters, claims-checked against the live site), `VIDEO-SCRIPT-and-DECK-v2.1.md` (earlier script and the 10-slide deck outline), `screens/` (storyboard screenshots) |
| `docs/FIT-CHECK-three-topics.md` | Why this topic was chosen against the judging criteria |

## Project rules

- English only: code, comments, UI, data, documents, video, deck.
- Google products only in the product: Gemini on Vertex AI, Cloud Run, Cloud SQL, Cloud Storage, Secret Manager.
- Invented data only. No keys in code or git.
- A person decides every step; nothing moves or rejects a candidate automatically.
- Every change is agreed by all team members and logged in `docs/FLOW-v2.1-glassbox.md` §7.
- Documents are signed "GlassBox Team".

## Run locally

Ruby 4.0.7 through rvm, PostgreSQL on localhost:5432. The database password comes from `~/.pgpass`, never from
this repository. Settings: `.env.example`.

```bash
source /usr/share/rvm/scripts/rvm
rvm ruby-4.0.7 do bundle install
rvm ruby-4.0.7 do bin/rails db:create db:migrate
rvm ruby-4.0.7 do bin/rails test
```

A second test database for parallel work: `TEST_DATABASE=glassbox_test_<name>`, created with
`RAILS_ENV=test bin/rails db:create db:schema:load`. Not `db:prepare`: on a new database it also runs the seeds, and the
seeded rows then break fixture loading in small test runs ("Foreign key violations found in your fixture data").

Public demo (the Cup deployment): `DEMO_MODE=1` opens the no-login door at `/demo` and the nightly reset (03:00 WIB);
`DEMO_RESET=off` pauses the schedule; `bin/rails glassbox:demo:reset` resets on demand.

### Demo accounts (invented; seeded by `db/seeds.rb`)

Three roles (17 Oct 2026). Sign in at `/session/new` with the password `glassbox-demo-2026`, or open `/demo`
(`DEMO_MODE=1`) and pick a role without a password.

| Role | What the role does | Email |
|---|---|---|
| HR Admin | Brief and ad with AI help, opens the applicant portal, starts the screening, calibration, technical-test case, every *Continue / Do not continue* decision with a reason, interview links, objections, offer upload | `hr@terangnusantara.example` |
| HR Manager | Reads each redacted CV and presses *Send to Gemini*, reviews flagged results, scores the technical test, agrees the salary | `manager@terangnusantara.example` |
| Superadmin | Every step and the system settings | `admin@glassbox.example` |

The person who prepares a vacancy is never the person who releases its CVs to Gemini; that rule binds the
Superadmin too. Applicants and interview assessors never sign in: they use the private link they receive.

## Team

GlassBox Team

Base code © CV Datakita Komunika, licensed to Team GlassBox for the Google Cloud AI Builder Cup 2026 only.
GlassBox additions © Team GlassBox. All rights reserved until the team chooses a licence.
