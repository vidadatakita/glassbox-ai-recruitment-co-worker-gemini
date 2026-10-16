module ApplicationHelper
  # A4/A5: true on the public Cup demo (DEMO_MODE=1). Views use it to leave out links and forms whose
  # routes are not drawn in demo mode (work queue, settings, AI salary advice, letters, appointments,
  # psychological-test score, data chat): a link to an undrawn route raises at render time.
  def demo_mode? = Glassbox::Settings.demo_mode?

  # FLOW §9 rule 3: "Tier HIGH · gemini-3.8-pro" beside every AI result, so a judge sees which model produced
  # which evidence (the one place a model id is shown to users, by team decision). job: the vacancy whose
  # locked mapping applies, when there is one.
  def ai_tier_badge(task, job: nil)
    tag.span(Screening::Config.tier_label(task, job:), class: "portal-state portal-state--muted ai-tier", title: "Model tier and id that produced this AI advice")
  end

  # The vacancy page: the mapping locked when the portal opened (rule 2), or the mapping in force now
  # for a vacancy whose portal has not opened yet.
  def ai_models_locked_line(job)
    tiers = job.ai_model_tiers.presence
    prefix = tiers ? "Models locked at portal open" : "Models in force now (locked when the portal opens)"
    tiers ||= Screening::Config.tiers_snapshot
    "#{prefix}: " + %w[high medium low].map { |t| "#{t.upcase} #{tiers.dig(t, 'model')}" }.join(", ")
  end

  # The roles that may open an applicant's page (Staff::ApplicationsController's role list). A screen the
  # admin can see must not link to a page the admin cannot open: the click would look broken instead
  # of the link being absent (GlassBox Team's live click, 16 Oct 2026). Admin keeps the system settings
  # and never the candidate data (UU PDP scope).
  APPLICATION_ROLES = %w[hr_pic consultant reviewer owner].freeze
  def can_open_applications? = APPLICATION_ROLES.include?(current_user&.role)

  # Whether an AI provider is configured (AI_* env). Without one every AI feature is unavailable:
  # its buttons are hidden and the people's own path (choose, score, agree, write) works as before.
  def ai_on? = Screening::Config.enabled?

  # The staff menu entry the current page belongs to, for its "active" state: a job's own pages
  # (brief, ad, applicants, scoring, screening, AI release) all count as "Lowongan Saya".
  # Specific sections first: the jobs pattern also covers the staff home, so it is the last resort.
  NAV_SECTIONS = {
    work_queue: %r{\A/staff/work_queue}, impact: %r{\A/staff/impact}, settings: %r{\A/staff/settings},
    jobs: %r{\A/staff(/jobs|/applications|/participations|/test_attempts|/screening_results|/ai_releases)?(/|\z)}
  }.freeze

  def nav_item(section, label, icon, path)
    active = NAV_SECTIONS.find { |_, re| request.path.match?(re) }&.first == section
    link_to path, class: ["side-menu__item", ("active" if active)].compact.join(" "), "aria-current": ("page" if active) do
      safe_join([tag.i(class: "fa #{icon} side-menu__icon"), tag.span(label, class: "side-menu__label")])
    end
  end

  # The job ad as the candidate reads it (and HR previews it): the ad is plain text written to one
  # convention (Briefs::Suggest AD_SYSTEM: a section heading on its own line, "- " for a list), so a
  # short line with no closing period followed by a list or paragraph is a heading, "- " lines are a
  # list, the rest are paragraphs. Escaped by content_tag; no markup from the text is trusted.
  def ad_html(text)
    lines = text.to_s.lines.map(&:strip).reject(&:empty?)
    item = ->(l) { l.start_with?("- ", "• ") }
    heading = ->(l, i) { !item.(l) && l.length <= 60 && !l.end_with?(".", ",", ":") && i < lines.size - 1 }
    blocks = lines.each_with_index.chunk_while { |(a, i), (b, _)| item.(a) == item.(b) && !heading.(a, i) && !heading.(b, i + 1) }
    safe_join(blocks.map do |group|
      first, i = group.first
      if group.size == 1 && heading.(first, i) then content_tag(:h3, first)
      elsif item.(first) then content_tag(:ul, safe_join(group.map { |l, _| content_tag(:li, l.sub(/\A[-•]\s+/, "")) }))
      else safe_join(group.map { |l, _| content_tag(:p, l) })
      end
    end)
  end
end
