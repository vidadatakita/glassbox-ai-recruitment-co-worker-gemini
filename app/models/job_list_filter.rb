# The vacancy list's filter (Vida, 17 Oct 2026: search by position, status, package, next-action owner,
# and city placement; every list is multi-select and the position search takes several words).
# A GET form; every value is checked against its list and an unknown value is ignored (shows all), never
# an error. Applied in Ruby to the org's vacancies (T1 sizes: a handful per company).
#
# Matching: values inside ONE field are alternatives (any of them matches); different fields must all
# match. Position terms are separated by commas ("accounting, admin" = title contains either).
class JobListFilter
  STATUSES = { "brief_draft" => "Brief draft", "not_opened" => "Portal not opened yet", "open" => "Portal open",
               "closed" => "Portal closed, selection running", "filled" => "Done: all places filled" }.freeze
  OWNERS = { "hr_admin" => "HR Admin", "hr_manager" => "HR Manager", "nobody" => "Nobody (done)" }.freeze
  PACKAGES = %w[1 2 3 4 5].freeze
  MAX_TERMS = 10

  attr_reader :q, :terms, :statuses, :packages, :owners, :cities, :city_options

  # The cities a vacancy is placed in: its placement list, or the old single location for a vacancy
  # written before placements existed (the same fallback as placement_summary).
  def self.cities_of(job) = (job.placements.presence || [job.location]).compact_blank.map { |c| c.to_s.strip }

  # Every city the org's vacancies are placed in, sorted; the City options. Only these are accepted.
  def self.cities_for(jobs) = jobs.flat_map { |job| cities_of(job) }.uniq(&:downcase).sort_by(&:downcase)

  # A field arrives as one value (a link, an old bookmark) or as a list (the multi-select's name[]).
  def self.values(param) = Array(param).flatten.map { |v| v.to_s.strip }.compact_blank.uniq

  def initialize(params, cities: [])
    @q = params[:q].to_s.strip[0, 200].presence
    @terms = @q.to_s.split(",").map { |t| t.strip.downcase }.compact_blank.uniq.first(MAX_TERMS)
    @statuses = self.class.values(params[:status]) & STATUSES.keys
    @packages = self.class.values(params[:package]) & PACKAGES
    @owners = self.class.values(params[:owner]) & OWNERS.keys
    @city_options = cities
    wanted = self.class.values(params[:city]).map(&:downcase)
    @cities = cities.select { |c| wanted.include?(c.downcase) }
  end

  def active? = [terms, statuses, packages, owners, cities].any?(&:present?)

  # steps: { job_id => VacancyNextStep::Step }. "both" (the selection mixes HR Admin and HR Manager steps)
  # appears under either owner.
  def apply(jobs, steps)
    jobs.select do |job|
      step = steps.fetch(job.id)
      title = job.title.to_s.downcase
      (terms.empty? || terms.any? { |t| title.include?(t) }) &&
        (statuses.empty? || statuses.include?(step.status.to_s)) &&
        (packages.empty? || packages.include?(job.package.to_s)) &&
        (owners.empty? || owners.include?(step.owner.to_s) || (step.owner == :both && (owners - ["nobody"]).any?)) &&
        (cities.empty? || self.class.cities_of(job).any? { |c| cities.any? { |w| w.casecmp?(c) } })
    end
  end
end
