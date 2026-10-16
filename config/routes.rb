Rails.application.routes.draw do
  # A4 (16 Oct 2026): on the public Cup demo (DEMO_MODE=1) only the twelve demo steps are routed.
  # Everything else the base can do stays in the code, un-drawn, so a client install keeps it and the
  # demo URL cannot reach a screen the judges were not shown. The flag is read once at boot.
  demo = Glassbox::Settings.demo_mode?

  resource :session
  unless demo
    resources :passwords, param: :token
    # D52 (1): staff "Sign in with Google". The OmniAuth middleware handles POST /auth/google_oauth2
    # only while Google login is configured; otherwise the POST reaches #unavailable. Google sends
    # the user back with a GET to the callback.
    post "auth/google_oauth2",          to: "google_sessions#unavailable", as: :google_login
    get  "auth/google_oauth2/callback", to: "google_sessions#create",      as: :google_login_callback
    get  "auth/failure",                to: "google_sessions#failure",     as: :google_login_failure
  end
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # --- Applicant portal (feature 02) ---------------------------------------------------------
  # Candidate pages: link only, no account (screens 10, 11).
  get  "apply/:code",          to: "lamar#show",   as: :lamar
  post "apply/:code/check",    to: "lamar#check",  as: :lamar_check
  post "apply/:code",          to: "lamar#create"

  # AI Builder Cup step 07: an invited interviewer scores from a link (no account).
  get  "score/:token", to: "interviewer_scores#show",   as: :interviewer_score
  post "score/:token", to: "interviewer_scores#create"
  scope "status/:token", as: :candidate_status, controller: :candidate_status do
    get  "/", action: :show, as: ""
    post "appointment/:appointment_id/attend",     action: :confirm_appointment, as: :confirm
    post "appointment/:appointment_id/reschedule", action: :reschedule,          as: :reschedule
    post "objection/:participation_id",            action: :object,              as: :object
    get  "withdraw-consent",                       action: :confirm_withdraw,    as: :confirm_withdraw
    post "withdraw-consent",                       action: :withdraw,            as: :withdraw
    post "offer/code",                             action: :send_offer_code,     as: :offer_code
    post "offer/open",                             action: :unlock_offer,        as: :unlock_offer
    post "offer/:offer_id/answer",                 action: :respond_offer,       as: :respond_offer
    get  "offer/:offer_id/letter",                 action: :offer_pdf,           as: :offer_pdf
  end
  # Feature 07 (D60 slice 3): the technical test, reached through the same private status link.
  scope "status/:token/technical-test", as: :candidate_status_test, controller: :candidate_tests do
    get  "/",            action: :show,      as: ""
    post "start",        action: :start,     as: :start
    get  "case-file",    action: :case_file, as: :case_file
    post "answer",       action: :answer,    as: :answer
  end

  # A5 (Cup rule "works without login"): the demo door, drawn only in DEMO_MODE=1 so a client install
  # never has the route. DemoSessionsController also answers 404 outside demo mode (belt and braces).
  if demo
    get  "demo", to: "demo_sessions#show",   as: :demo
    post "demo", to: "demo_sessions#create"
  end

  get  "new-link", to: "link_requests#new",    as: :new_link_request
  post "new-link", to: "link_requests#create", as: :link_requests

  # Staff screens (account).
  namespace :staff do
    root to: "jobs#index"
    # Feature 03, "New vacancy" (blueprint §3.1 screen 2). Declared before `resources :jobs` so
    # /staff/jobs/new is not read as show(id: "new").
    get  "jobs/new", to: "job_briefs#new",    as: :new_job
    post "jobs",     to: "job_briefs#create", as: :create_job
    resources :jobs, only: %i[index show] do
      patch :approve_ad, on: :member
      get   "brief",       to: "job_briefs#show",   as: :brief
      get   "brief/:step", to: "job_briefs#edit",   as: :brief_step, constraints: { step: /[1-4]/ }
      patch "brief/:step", to: "job_briefs#update", constraints: { step: /[1-4]/ }
      # AI Builder Cup step 01: the AI proposes the brief from the job title (Briefs::Suggest).
      post  "brief/ai-advice", to: "brief_suggestions#create", as: :brief_suggestion
      # Screening standard, Appendix D structure: the discrimination test on the requirements, run and
      # decided line by line on the brief page (Briefs::RequirementCheck).
      post  "requirement-check",          to: "requirement_checks#create", as: :requirement_check
      post  "requirement-check/:line_id", to: "requirement_checks#decide", as: :requirement_check_decision
      # AI Builder Cup step 02: the job ad, written (or proposed by the AI) and checked before HR approves.
      get   "ad",          to: "job_ads#edit",             as: :ad
      post  "ad",          to: "job_ads#update" # also "Rewrite with AI" (ai=1), same form
      # "Complete brief" from the LAST step: step 5 when the package runs the technical test.
      post  "brief/complete", to: "job_briefs#complete", as: :brief_complete
      # Feature 07 (D60 slice 2): brief step 5 "Technical test", its own controller (versions, upload,
      # HR approval). Shown only when the package runs S2. Its own address, not brief/5: the
      # feature-03 contract "brief/:step is 1-4, anything else is not found" stays as it was.
      get  "technical-test",                to: "test_cases#edit",      as: :test_case_step
      post "test_cases",                    to: "test_cases#save",      as: :test_cases
      post "test_cases/:id/approve",        to: "test_cases#approve",   as: :test_case_approve
      get  "test_cases/:id/case_file",      to: "test_cases#case_file", as: :test_case_file
      # Feature 07 (D60 slice 5): the reviewer scores the technical-test answers on the rubric.
      get  "technical-test/scoring",        to: "test_scorings#index",  as: :test_scorings
      post "portal/open",   to: "portal_windows#open",   as: :portal_open
      post "portal/close",  to: "portal_windows#close",  as: :portal_close
      post "portal/reopen", to: "portal_windows#reopen", as: :portal_reopen
      # Feature 06, S1 AI screening (blueprint §3.1 screen 8, §4.1).
      post "screening/start",       to: "screenings#start",       as: :screening_start
      post "screening/retry",       to: "screenings#retry_failed", as: :screening_retry
      get  "screening/review",      to: "screenings#review",      as: :screening_review
      get  "screening/calibration", to: "screenings#calibration", as: :screening_calibration
      # Feature 09 (D51 B): "Review before AI", the reviewer's release list for one job.
      get  "ai-review",             to: "ai_releases#index",      as: :ai_releases
      # Fairness check (FLOW v2.1, new in v2.1): one invented CV, swapped before redaction, HIGH tier.
      get  "fairness-check",        to: "fairness_checks#show",   as: :fairness_check
      post "fairness-check",        to: "fairness_checks#create"
      # Feature 08, the screening report (D61, D62): list, xlsx, candidate detail, and
      # the three writes on the detail page (label, narrative approval, hiring manager's pick).
      get  "screening-report",                                 to: "screening_reports#index",  as: :screening_report
      get  "screening-report/excel",                           to: "screening_reports#export", as: :screening_report_export
      get  "screening-report/:application_id",                 to: "screening_reports#show",   as: :screening_report_candidate,
                                                               constraints: { application_id: /\d+/ }
      post "screening-report/:application_id/label",           to: "screening_report_actions#label",               as: :screening_report_label
      post "screening-report/:application_id/narratives",      to: "screening_report_actions#approve_narratives",  as: :screening_report_narratives
      post "screening-report/:application_id/hiring-manager-pick", to: "screening_report_actions#user_recommendation", as: :screening_report_user_recommendation
    end
    post "screening_results/:id/review", to: "screenings#create_review", as: :screening_result_review
    # Feature 09 (D51 B): one text version, and the reviewer's three actions on it.
    get  "ai_releases/:id",              to: "ai_releases#show",    as: :ai_release
    post "ai_releases/:id/send",         to: "ai_releases#release", as: :ai_release_send
    post "ai_releases/:id/cut",          to: "ai_releases#cut",     as: :ai_release_cut
    post "ai_releases/:id/not-sent",     to: "ai_releases#decline", as: :ai_release_decline
    post "test_attempts/:id/score",      to: "test_scorings#create",      as: :test_attempt_score
    get  "test_attempts/:id/answer",     to: "test_scorings#answer_file", as: :test_attempt_answer
    # AI Builder Cup step 05: the reviewer previews the exact text, then sends it for an AI proposal.
    get  "test_attempts/:id/ai",         to: "test_scorings#ai_preview",  as: :test_attempt_ai
    post "test_attempts/:id/ai",         to: "test_scorings#ai_score"
    resources :applications, only: :show do
      get :cv, on: :member
      # The owner agrees the salary (step 11). The AI's salary suggestion is NOT on the demo path
      # (FLOW v2.1 cut #6: the AI never sees or suggests money); the letters (draft + send) are roadmap.
      post "salary/ai-advice", to: "salaries#recommend", as: :salary_recommendation unless demo
      post "salary",           to: "salaries#agree",     as: :salary
      unless demo
        post "letter/draft",   to: "letters#draft",      as: :letter_draft
        post "letter",         to: "letters#deliver",    as: :letter
      end
      resources :offers, only: :create
    end
    resources :participations, only: [] do
      # Calendar appointments (Google Calendar) and the hand-entered psychological-test score are
      # outside the twelve demo steps.
      resources :appointments, only: :create unless demo
      # AI Builder Cup step 06: Interview 1 scorecard, AI advice, the HR owner's choice.
      post "interview",   to: "progressions#interview", as: :interview
      post "score",       to: "progressions#manual_score", as: :manual_score unless demo
      post "ai-advice",   to: "progressions#recommend", as: :recommendation
      post "choice",      to: "progressions#choose",    as: :choice
      # AI Builder Cup step 07: a link for an interviewer without an account.
      post "assessor",    to: "progressions#invite",    as: :interviewer
      post "calibration", to: "screenings#judge",        as: :calibration
      get  "cv_text",     to: "screenings#cv_text",      as: :cv_text
      post "cv_text",     to: "screenings#save_cv_text"
    end
    unless demo
      resources :appointments, only: :update do
        post :calendar, on: :member # D52 (4): resend the invitation after a failed calendar sync
      end
    end
    post "offers/:id/followed_up", to: "offers#followed_up", as: :offer_followed_up
    post "objections/:id/answer",  to: "objections#answer",  as: :objection_answer
    # AI Builder Cup "before / after": the impact summary.
    get "impact", to: "impacts#show", as: :impact
    # The staff data chat ("Ask AI") stays on the demo (GlassBox Team, 16 Oct 2026, overriding cut #8): it
    # reads only summaries of the user's own vacancies through fixed read-only functions.
    get  "ask", to: "data_chats#show", as: :data_chat
    post "ask", to: "data_chats#create"
    unless demo
      # The work queue and the system settings are not demo steps.
      resource :work_queue, only: :show do
        post "link_requests/:id/handled", action: :handle_link_request, as: :handle_link_request
        post "mail_failures/:id/handled", action: :handle_mail_failure, as: :handle_mail_failure
      end
      resource :settings, only: %i[show update] do
        post :consent, action: :create_consent
      end
    end
  end
  root to: redirect("/staff")

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
end
