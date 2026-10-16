# THE HOUSE BUTTON. One definition, used everywhere, so a button cannot be
# wrong on one screen and right on another.
#
# Owner, 2026-09-12: every button in the application adopts the HRTemplate
# "label buttons" layout — a tinted icon box fused to the leading (or trailing)
# edge of a coloured button. The CSS for it already ships in this project
# (template/assets/css/styles.css: .label-btn, .label-btn-icon, .label-end,
# .btn-list) and the layout already links that file, so nothing is ported here;
# this helper only produces the markup those rules expect.
#
# ⛔ WHY A HELPER AND NOT A FIND-AND-REPLACE OVER 503 FILES. Two reasons, both
# paid for already:
#
#   1. `f.submit` renders <input type="submit">, which CANNOT contain an <i>.
#      Every label button therefore has to become a <button>, and that swap is
#      exactly where a submit silently loses its name/value — the SPKL overtime
#      incident, where every approval appeared to succeed while no stage
#      advanced. This helper keeps `name="commit"` and `value="<label>"`, the
#      identical pair `f.submit` sent, so the request is unchanged.
#   2. A rule that lives in a helper is applied by writing ordinary code. A rule
#      that lives only in a document is applied by remembering it.
#
# ⛔ NEVER add `disabled` or `data-disable-with` here, and never accept them
# through html_options. A disabled control is not a successful control, so the
# browser drops its name and value from the request and the controller matches
# no branch — the screen looks like it worked and the business outcome is
# absent. Double-submit is prevented by blocking the SECOND submit event, never
# by disabling the button. House hard rule.
#
# Icons are FontAwesome (`fa fa-*`), not the template's Remix set: 452 view
# files already use FontAwesome and the view/detail icon is fixed at `fa fa-plus`
# by house rule. `.label-btn-icon` styles the icon BOX, not the glyph, so it is
# icon-font agnostic and FontAwesome sits in it correctly.
module LabelButtonHelper
  # Colour carries meaning, and only meaning (owner ruling relayed 2026-09-12,
  # and the design canon says the same): green approves, amber returns work,
  # red destroys, primary is the ordinary forward action. A rejection drawn in
  # green — which app/views/loans/_form_reject.html.erb does today — tells a
  # colour-blind operator nothing and tells everyone else the wrong thing.
  PURPOSE_VARIANT = {
    :approve => "btn-success",
    :submit  => "btn-primary",
    :rework  => "btn-warning",
    :destroy => "btn-danger",
    :neutral => "btn-light"
  }.freeze

  # A submit button. `label` is the visible text AND the submitted commit value.
  #
  #   label_button "Simpan Pengajuan", "fa-save"
  #   label_button "Setujui", "fa-check", :purpose => :approve
  #   label_button "Batalkan", "fa-times", :purpose => :destroy, :icon_end => true
  #
  # Pass `:name => nil` for a button that must submit nothing (a GET filter),
  # matching what `submit_tag` did on those forms.
  def label_button(label, icon, html_options = {})
    options = html_options.dup
    icon_end = options.delete(:icon_end)
    classes = label_button_classes(options.delete(:purpose), options.delete(:class), icon_end)
    options = { :type => "submit", :name => "commit", :value => label }.merge(options)
    options[:class] = classes
    button_tag(options) { label_button_body(label, icon, icon_end) }
  end

  # The same shape for a navigation action (`link_to`). No name/value: a link
  # submits nothing, so there is nothing to preserve.
  def label_link(label, icon, url, html_options = {})
    options = html_options.dup
    icon_end = options.delete(:icon_end)
    options[:class] = label_button_classes(options.delete(:purpose), options.delete(:class), icon_end)
    link_to(url, options) { label_button_body(label, icon, icon_end) }
  end

  private

  # `label-end` moves the icon box to the trailing edge. Reserved for actions
  # that LEAVE or UNDO (cancel, back, discard) so the direction of the icon
  # matches the direction of the action; everything else keeps it leading.
  #
  # ⛔ NO `rounded-pill`. The HRTemplate offers it and the house visual identity
  # (layout-decoration §2) requires squarer corners, radius <= 0.5rem. Where the
  # reference and the house identity disagree, the house wins — do not add it
  # back because the template screenshot shows pills.
  def label_button_classes(purpose, extra, icon_end)
    variant = PURPOSE_VARIANT[purpose] || PURPOSE_VARIANT[:submit]
    # A caller-supplied btn-* variant wins: some screens legitimately need a
    # colour this list does not name, and silently overriding it would make the
    # helper harder to use than raw markup.
    variant = nil if extra.to_s =~ /\bbtn-(primary|secondary|success|danger|warning|info|light|dark|default)\b/
    ["btn", variant, "label-btn", (icon_end ? "label-end" : nil), extra].compact.join(" ")
  end

  # The icon is decorative and hidden from screen readers: the visible label is
  # already the accessible name, so announcing the glyph would read it twice.
  def label_button_body(label, icon, icon_end)
    glyph = content_tag(:i, "", :class => "fa #{icon} label-btn-icon #{icon_end ? 'ms-2' : 'me-2'}",
                                "aria-hidden" => "true")
    icon_end ? safe_join([label, glyph], " ") : safe_join([glyph, label], " ")
  end
end
