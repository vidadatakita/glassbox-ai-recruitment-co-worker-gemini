# The system settings page on the public demo (DEMO_MODE=1, 18 Oct 2026): shown READ-ONLY. The saving
# routes are not drawn there, so each settings form renders as a disabled fieldset with its values and
# no Save button, and nothing on the page can submit. Outside demo mode these are the ordinary forms.
module SettingsHelper
  def settings_form(url:, method:, scope: nil, **options, &block)
    return form_with(url:, method:, scope:, data: { turbo: false, submit_guard: true }, **options, &block) unless demo_mode?

    content_tag(:fieldset, disabled: true, class: ["settings-readonly", options[:class]].compact.join(" ")) do
      scope ? fields(scope, &block) : capture(&block)
    end
  end

  # No Save button on the demo: there is no form to submit (a hidden button, never a disabled one).
  def settings_save(label, icon) = demo_mode? ? nil : label_button(label, icon)
end
