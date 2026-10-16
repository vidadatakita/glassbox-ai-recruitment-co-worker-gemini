# The gate "Seleksi CV dan Tes Teknis" on Beranda Lowongan (D60, plan §a): both stages' figures side
# by side and the gate result per applicant. Everything is computed from rows loaded here once
# (participations with their applications, current decisions in one query); the view only prints.
class GateBoard
  Row = Data.define(:s1, :s2, :s1_decision, :s2_decision, :result)
  Counts = Data.define(:entered, :passed, :eliminated, :waiting)

  attr_reader :job

  def initialize(job)
    @job = job
  end

  def s1 = members.find { |stage| stage.code == "S1" }
  def s2 = members.find { |stage| stage.code == "S2" }
  def applicable? = !s1.nil? && !s2.nil?
  def name = Stage::GATES.fetch(s1.gate)

  # S1 participations in id order: the same list ScreeningBoard numbers, so "Kandidat 07" is the
  # same person on the screening box and here (ScreeningHelper#screening_person).
  def participations = @participations ||= loaded.select { |p| p.stage_id == s1.id }

  def rows
    @rows ||= begin
      s2_by_application = loaded.select { |p| p.stage_id == s2.id }.index_by(&:job_application_id)
      participations.map do |p1|
        p2 = s2_by_application[p1.job_application_id]
        d1 = decisions[p1.id]
        d2 = p2 && decisions[p2.id]
        Row.new(s1: p1, s2: p2, s1_decision: d1, s2_decision: d2, result: Gates::Result.of(d1, d2))
      end.sort_by { |row| [RESULT_ORDER.fetch(row.result), row.s1.id] }
    end
  end

  # Applicants still needing a decision come first: that is what someone has to act on.
  RESULT_ORDER = { open: 0, passed: 1, not_passed: 2 }.freeze

  def counts_for(stage)
    list = loaded.select { |p| p.stage_id == stage.id }
    outcomes = list.map { |p| decisions[p.id]&.outcome }
    Counts.new(entered: list.size, passed: outcomes.count("pass"), eliminated: outcomes.count("eliminate"),
               waiting: outcomes.count { |o| o.nil? || o == "review" })
  end

  def result_count(result) = rows.count { |row| row.result == result }
  def total = rows.size

  def percent(part) = total.zero? ? 0 : (part * 100.0 / total).round

  private

  def members = @members ||= job.stages.where(gate: "screening").order(:code).to_a

  def loaded
    @loaded ||= Participation.where(stage_id: members.map(&:id)).includes(job_application: :candidate).order(:id).to_a
  end

  def decisions
    @decisions ||= Decision.current.where(participation_id: loaded.map(&:id)).index_by(&:participation_id)
  end
end
