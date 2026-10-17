# Screen settings (ONP-3). Declared in Glassbox::Settings::SCREEN_KEYS; changed only through
# SystemSettings::Update, which writes an audit row.
class SystemSetting < ApplicationRecord
  validates :key, inclusion: { in: Glassbox::Settings::SCREEN_KEYS.keys }, uniqueness: { scope: :client_company_id }
  validates :value, presence: true

  belongs_to :client_company, optional: true

  # company: the client company whose value applies (its own row), else the install-wide row
  # (client_company_id NULL), else the declared default.
  def self.value_of(key, company: nil)
    spec = Glassbox::Settings::SCREEN_KEYS.fetch(key)
    rows = where(key:, client_company_id: [company&.id, nil].uniq).to_a
    raw = (rows.find { |r| company && r.client_company_id == company.id } || rows.find { |r| r.client_company_id.nil? })&.value
    return spec[:default] if raw.nil?

    case spec[:type]
    when :integer then Integer(raw, 10)
    when :boolean then raw == "true"
    when :list then raw.split(",")
    else raw
    end
  end

  # Days after the job closes; nil until someone sets it (D32).
  def self.retention_days(company: nil) = value_of("retention_days", company:)
  def self.verified_line?(company: nil) = value_of("verified_line", company:)
  def self.ai_interview?(company: nil) = value_of("ai_interview", company:)
end
