# AI Recruitment Co-worker

**Gemini reads the CVs. Your team makes the call.**

An AI co-worker for every hiring decision: faster for the recruiter, fair for the candidate, explainable for the
owner. Built with Gemini on Google Cloud for the **Google Cloud AI Builder Cup 2026**, track **Future of Work &
Enterprise Productivity**.

> **Status: in development.** This repository is a preview of what we are building. Features below describe the
> product direction, not finished software.

---

## The problem

One vacancy can bring hundreds of CVs. In many organizations, hiring still happens by hand: a job title that says
little about the job, CVs read late at night, interviews remembered rather than scored, and an offer that nobody can
explain a month later. Recruiters spend their days reading instead of deciding. Candidates wait for weeks. Owners
cannot tell whether they hired the best person who applied.

## The idea

A co-worker for hiring that does the reading, keeps the evidence and explains its advice, while a person makes every
decision.

## How it works, at a glance

1. **Job brief:** Gemini turns a job title into a clear brief; the recruiter adjusts and approves it.
2. **Job ad:** written from the approved brief.
3. **Broadcast:** a tailored post for each channel, each with its own link.
4. **Apply:** candidates apply from a phone, then take a short task based on the real job.
5. **Screening:** Gemini reviews each application against the approved brief and explains its view.
6. **Interview 1:** the team scores; Gemini recommends; the recruiter decides.
7. **Interview 2:** the hiring manager scores; Gemini recommends; the team decides.
8. **Decision:** the owner decides, with the evidence in one place.
9. **Close-out:** every candidate gets an answer.

## What makes it different

- **People decide.** Gemini suggests; a named person chooses at every step.
- **Evidence first.** Every recommendation points to what it is based on.
- **Fair by design.** Personal details that must not influence a hiring decision are never sent to the model.

More in [VISION.md](VISION.md) and [RESPONSIBLE-AI.md](RESPONSIBLE-AI.md). A visual preview is in
[teaser.html](teaser.html).

## Read more

- [What if every hiring decision had a co-worker? (Medium)](https://medium.com/@vida.harsianti/what-if-every-hiring-decision-had-a-co-worker-0738c758961d)
- [The same story on datakita.org](https://datakita.org/en/blog/gemini-mengusulkan-hr-memutuskan-rekrutmen-ai-hr-kolaborasi-ai-recruitment-without-guessing-ai-hiring-co-worker-gemini)

## Built with

- Gemini (Google Gen AI SDK)
- Google Cloud (Cloud Run, Cloud Storage)

## Data

All data shown or used in this project is synthetic. No real candidate or company data is included.

## Team

DataKita, Indonesia. [Team member names as registered for the Cup.]

---

© 2026 DataKita. All rights reserved. No licence is granted to copy, modify or distribute the contents of this
repository.
