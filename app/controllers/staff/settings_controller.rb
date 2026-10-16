module Staff
  # Settings (ONP-3): the screen settings and the consent text versions (D35). Admin only.
  # Every change writes an audit row; the button reads Save (house rule on button verbs).
  class SettingsController < BaseController
    before_action -> { require_role!(:admin) }

    def show
      # The settings this user edits: their company's under TENANCY=multi, else the install-wide ones.
      company = ClientCompany.find_by(id: Glassbox::Settings.settings_company_id(current_user))
      @retention_days = SystemSetting.retention_days(company:)
      @verified_line = SystemSetting.verified_line?(company:)
      @cv_sections = Screening::CvSections.enabled(company:)
      @consent = ConsentTemplate.in_force(company:)
      @upcoming = ConsentTemplate.upcoming(company:)
      @changes = SettingChange.where(client_company_id: company&.id).order(created_at: :desc).limit(20)
      @blockers = Portal::ConsentReadiness.blockers(company:)
      @baselines = %w[baseline_hours_to_answer baseline_minutes_per_cv baseline_reasoned_pct].to_h { |k| [k, SystemSetting.value_of(k, company:)] }
      @google = GoogleIntegration::Status.all # D52: state only, never a secret
    end

    def update
      Portal::UpdateSetting.call(key: params[:key], value: params[:value], actor: current_user)
      redirect_to staff_settings_path, notice: "Settings saved."
    rescue Portal::UpdateSetting::Invalid => e
      redirect_to staff_settings_path, alert: e.message
    end

    # A new consent version. It takes effect at effective_from, which must be in the future when
    # a version is already in force, so the change is announced first (Pasal 21(2), D35).
    def create_consent
      Portal::PublishConsent.call(params: params.require(:consent).permit(*ConsentTemplate::SECTIONS.keys, :effective_from),
                                  actor: current_user)
      redirect_to staff_settings_path, notice: "New consent text version saved."
    rescue Portal::PublishConsent::Invalid => e
      redirect_to staff_settings_path, alert: e.message
    end
  end
end
