module Screening
  # Blueprint §4.1 step 4 and P3: the S1 rubric IS the brief's three-tier requirements. No second
  # rubric exists, so this class only reads Requirement rows and adds nothing of its own.
  #
  # The payload sent to the model holds, per requirement, ONLY: a stable id ("R<id>"), the tier,
  # the requirement text and the CV evidence the brief names. Nothing about the job (company,
  # salary, title) and nothing about the candidate travels with it (§5.1 row 2: "Rubric payload
  # contains only the brief's requirements").
  class Rubric
    Criterion = Data.define(:key, :requirement_id, :tier, :text, :cv_evidence, :weight)

    TIERS = %w[wajib sebaiknya nilai_tambah].freeze
    # Judgements the model may return per tier. Wajib: met / not met (§4.1 step 4). Sebaiknya and
    # nilai tambah: 0-3 against the CV evidence named in the brief.
    JUDGEMENTS = {
      "wajib" => %w[met not_met],
      "sebaiknya" => %w[0 1 2 3],
      "nilai_tambah" => %w[0 1 2 3]
    }.freeze

    class Incomplete < StandardError; end

    attr_reader :criteria

    def self.for(job) = new(job.requirements.reorder(:tier, :position, :id).to_a)

    def initialize(requirements)
      @criteria = requirements.sort_by { |r| [TIERS.index(r.tier) || 9, r.position.to_i, r.id.to_i] }.map do |r|
        Criterion.new(key: "R#{r.id}", requirement_id: r.id, tier: r.tier, text: r.text.to_s.strip,
                      cv_evidence: r.cv_evidence.to_s.strip, weight: r.weight)
      end
    end

    # A rubric the score cannot be computed from is refused before any API call: the sebaiknya
    # weights must exist and sum to exactly 100 (blueprint §2.1, checked again here because a draft
    # brief may be half-filled).
    def problems
      found = []
      found << "The vacancy brief has no requirements yet." if criteria.empty?
      weights = criteria.select { |c| c.tier == "sebaiknya" }.map { |c| c.weight.to_i }
      found << "The should-have weights must add up to 100 (now #{weights.sum})." unless weights.sum == 100
      found
    end

    def payload
      criteria.map do |c|
        { "id" => c.key, "tier" => c.tier, "requirement" => c.text, "cv_evidence" => c.cv_evidence }
      end
    end

    # Identifies the rubric a result was produced against. Weights are part of it: they change the
    # score even when the text sent is the same.
    def digest
      Digest::SHA256.hexdigest(JSON.generate(criteria.map { |c| [c.key, c.tier, c.text, c.cv_evidence, c.weight] }))
    end

    def by_key = @by_key ||= criteria.index_by(&:key)
  end
end
