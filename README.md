# GlassBox: AI Recruitment Co-worker

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
| `docs/VIDEO-SCRIPT-and-DECK-v2.1.md` | Video script (10 scenes) and 10-slide deck outline, with the claims-check table |
| `docs/FIT-CHECK-three-topics.md` | Why this topic was chosen against the judging criteria |

## Project rules

- English only: code, comments, UI, data, documents, video, deck.
- Google products only in the product: Gemini on Vertex AI, Cloud Run, Cloud SQL, Cloud Storage, Secret Manager.
  No claim is made about which coding assistant wrote the code.
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

A second test database for a parallel session: `TEST_DATABASE=glassbox_test_<name>`, created with
`RAILS_ENV=test bin/rails db:create db:schema:load`. Not `db:prepare`: on a new database it also runs the seeds, and the
seeded rows then break fixture loading in small test runs ("Foreign key violations found in your fixture data").

Public demo (the Cup deployment): `DEMO_MODE=1` opens the no-login door at `/demo` and the nightly reset (03:00 WIB);
`DEMO_RESET=off` pauses the schedule; `bin/rails glassbox:demo:reset` resets on demand.

### Demo accounts (invented; seeded by `db/seeds.rb`)

Sign in at `/session/new`. With `DEMO_MODE=1` the door at `/demo` opens the first three roles without a password.
The password for every account is `glassbox-demo-2026`.

| Role | What the role does on the demo path | Email |
|---|---|---|
| HR owner | Writes the brief with AI help, approves the ad, opens the portal, takes every *Continue / Do not continue* decision with a reason | `hr@terangnusantara.example` |
| Reviewer | Reads each redacted CV and presses *Send to Gemini*; nothing reaches the model before that click | `reviewer@glassbox.example` |
| Owner | Sees the passed candidates beside the salary band and agrees the number | `owner@terangnusantara.example` |
| Consultant | Calibrates the AI screening against their own judgement; never the reviewer of the same vacancy | `consultant@glassbox.example` |
| Admin | System settings (retention period, consent text, CV sections sent to the AI); hidden on the public demo | `admin@terangnusantara.example` |

Applicants and interview assessors never sign in: they use the private link they receive. The demo company is
PT Terang Nusantara (invented), Kota Tangerang. `LEGACY_DEMO_SEEDS=1` adds the earlier feature demos (Indonesian
titles) to a development database; the public demo never loads them.

Deploy to Google Cloud with `bin/gcp setup` once, then `bin/gcp deploy`.

## Team

GlassBox Team

Base code © CV Datakita Komunika, licensed to Team GlassBox for the Google Cloud AI Builder Cup 2026 only.
GlassBox additions © Team GlassBox. All rights reserved until the team chooses a licence.
