module PortalHelper
  # Salary band in integer rupiah, digits grouped the Indonesian way: "Rp5.200.000–6.000.000/month".
  def salary_band(job)
    fmt = ->(n) { number_with_delimiter(n, delimiter: ".") }
    "Rp#{fmt.(job.salary_min)}–#{fmt.(job.salary_max)}/month"
  end

  WINDOW_LABELS = {
    never_opened: ["Not opened yet", "muted"], open: ["Open", "success"],
    closed_by_hr: ["Closed by HR", "muted"], closed_by_date: ["Closed automatically (date)", "muted"],
    closed_by_quota: ["Closed automatically (quota)", "muted"],
    closed_by_stage: ["Closed (CV screening complete)", "muted"],
    closed_by_settings: ["Not accepting applications (consent text incomplete)", "muted"]
  }.freeze

  def window_label(window) = WINDOW_LABELS.fetch(window.state).first

  # Drawn with the house status tints (staff.css .portal-state--*), readable on the card. The theme's
  # bg-light-transparent badge was nearly invisible on a white card (screenshot 2026-10-10 03:1x).
  def window_badge(window)
    label, tone = WINDOW_LABELS.fetch(window.state)
    content_tag(:span, label, class: "portal-state portal-state--#{tone}")
  end

  def wib(time) = time && l(time.in_time_zone, format: :long_wib)

  # A share of `part` in `whole` as "n of m"; never divides by zero.
  def share_text(part, whole) = "#{part} of #{whole}"

  # The candidate status link the consultant can paste into WhatsApp. The raw token is not
  # stored, so staff cannot rebuild a candidate's link; they re-issue one instead (D36).
  def whatsapp_url(phone, text)
    digits = phone.to_s.gsub(/\D/, "").sub(/\A0/, "62")
    "https://wa.me/#{digits}?text=#{ERB::Util.url_encode(text)}"
  end
end
