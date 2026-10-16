# The consent text shown on Lamar (D35). One row per version; a version is never edited after
# insert (database trigger), so an application's consent_template_id always points at the exact
# words the candidate agreed to (UU 27/2022 Pasal 22(1)).
#
# The text is a DRAFT with placeholder lines until the client's legal reviews it; the admin
# screen says so. The retention line is not stored here: it is rendered from the retention
# setting in force, and the application stores that number too (consent_retention_days).
class ConsentTemplate < ApplicationRecord
  include AppendOnly

  # Pasal 21(1) items in display order, with the heading shown for each.
  SECTIONS = {
    controller_identity: "Data controller",
    legal_basis: "Legal basis",
    purpose: "Purpose",
    data_types: "Types of data and their relevance",
    collected_items: "Data collected",
    processing_duration: "Processing period",
    rights: "Your rights"
  }.freeze

  # The starting draft (D35, 2026-10-10). Pre-fills the admin form when no version exists; it is
  # never saved by itself, so an install has no consent text until an admin saves one. The
  # purpose line is the wording of the approved portal design; every other line is a PLACEHOLDER
  # for the client's legal to write; the literal "[PLACEHOLDER" prefix is what placeholder_sections
  # and the D38 portal block key on, so it must stay. Final wording stays with the owner and counsel.
  DRAFT = {
    controller_identity: "[PLACEHOLDER: name and address of the employer as data controller; GlassBox as data processor on the company's behalf.]",
    legal_basis: "[PLACEHOLDER: legal basis for processing, e.g. your consent, set by the company's legal team.]",
    purpose: "Your data is used only for this recruitment process.",
    data_types: "[PLACEHOLDER: types of personal data processed and their relevance to recruitment.]",
    collected_items: "Full name, WhatsApp number, e-mail, CV, and answers to the requirement questions. [PLACEHOLDER: check with legal.]",
    processing_duration: "[PLACEHOLDER: processing period for the duration of the selection process.]",
    rights: "[PLACEHOLDER: your rights to access and obtain a copy, to correct, to withdraw consent, to request deletion, and to object to a decision taken solely by automated means.] You can withdraw your consent from the application status page."
  }.freeze

  # D39: shown under "Full details" on Lamar; the other sections are in the open layer.
  DETAIL_SECTIONS = %i[data_types collected_items processing_duration].freeze

  validates :version, presence: true, uniqueness: { scope: :client_company_id }

  belongs_to :client_company, optional: true

  # A company that wrote its own consent text uses only its own versions (it is the data
  # controller, Pasal 21); otherwise the install-wide text (client_company_id NULL) applies.
  def self.for_company(company)
    own = company && where(client_company_id: company.id)
    own&.exists? ? own : where(client_company_id: nil)
  end
  validates(*SECTIONS.keys, presence: true)
  validates :effective_from, presence: true

  # The version in force at `now`: the latest one whose effective_from has passed.
  def self.in_force(now = Time.current, company: nil)
    for_company(company).where(effective_from: ..now).order(effective_from: :desc, id: :desc).first
  end

  # A version announced but not yet in force (Pasal 21(2): a change is announced before it applies).
  def self.upcoming(now = Time.current, company: nil)
    for_company(company).where("effective_from > ?", now).order(:effective_from).first
  end

  def draft? = placeholder_sections.any?

  # Headings of the sections that still contain a [PLACEHOLDER] (D38 blocks the portal on these).
  def placeholder_sections
    SECTIONS.filter_map { |field, heading| heading if public_send(field).to_s.include?("[PLACEHOLDER") }
  end
end
