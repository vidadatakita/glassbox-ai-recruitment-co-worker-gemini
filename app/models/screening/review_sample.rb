module Screening
  # Blueprint §4.1 step 8: the reviewer confirms every elimination and a RANDOM 10% of passes. The
  # sample must be reproducible and recorded (task D50 brief).
  #
  # How: a job's passing results are numbered 1, 2, 3 ... in the order they arrive (pass_ordinal,
  # stored on the ScreeningResult under a lock on the job row). They fall into blocks of ten
  # (1-10, 11-20, ...). In each block exactly ONE position is sampled, chosen by
  # SHA-256(seed + block number) mod 10. So:
  #   - exactly 1 in every 10 passes is reviewed, not "about 10%" (a per-pass coin flip would give
  #     0 of 10 about a third of the time);
  #   - anyone holding the seed can recompute every choice (reproducible), and the choice is stored
  #     on the result anyway (recorded);
  #   - the consultant cannot predict which pass will be checked, because the seed is random,
  #     set by the system, and shown nowhere (rule 19, actor who benefits).
  # A block that is not full yet may not have reached its sampled position; with fewer than ten
  # passes the sample can be empty. Accepted and recorded as an open item (feature record 06 §8).
  module ReviewSample
    BLOCK = 10

    module_function

    def sampled?(seed:, ordinal:)
      raise ArgumentError, "ordinal starts at 1" unless ordinal.is_a?(Integer) && ordinal >= 1
      raise ArgumentError, "seed is required" if seed.to_s.empty?

      block, position = (ordinal - 1).divmod(BLOCK)
      position == chosen_position(seed, block)
    end

    def chosen_position(seed, block) = Digest::SHA256.hexdigest("#{seed}:#{block}")[0, 8].to_i(16) % BLOCK

    def new_seed = SecureRandom.hex(16)
  end
end
