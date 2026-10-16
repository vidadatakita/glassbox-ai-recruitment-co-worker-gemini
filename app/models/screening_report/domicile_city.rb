module ScreeningReport
  # D54: the optional "Kota domisili" from Lamar. City or kabupaten only, never an address: spaces
  # squeezed, at most 60 characters, no digits, and no street/RT/RW/kelurahan shapes (Jl., Gg., RT,
  # RW, Kel., Kec., Blok, No.). Refused with a field message, so the candidate retypes it
  # instead of the system storing an address it must not hold. Never sent to the AI, never scored.
  # The database CHECK job_applications_domicile_city_shape repeats the length and digit rule.
  module DomicileCity
    MAX = 60
    ADDRESS = /\b(jl|jln|jalan|gg|gang|rt|rw|kel|kelurahan|kec|kecamatan|blok|no|komp|perum)\b\.?/i
    # Suggestions for the form's datalist only; any other city is accepted.
    SUGGESTIONS = %w[Jakarta Bekasi Bogor Depok Tangerang Bandung Karawang Cikarang Semarang Surabaya
                     Yogyakarta Medan Makassar Palembang Batam Denpasar Balikpapan Malang Solo Serang].freeze
    Parsed = Data.define(:value, :error)

    module_function

    def parse(raw)
      text = raw.to_s.squish
      return Parsed.new(value: nil, error: nil) if text.empty?
      return refused("Enter the city or regency only, at most #{MAX} characters.") if text.length > MAX
      return refused("Enter the city or regency name only, without an address or digits.") if text.match?(/\d/) || text.match?(ADDRESS)

      Parsed.new(value: text, error: nil)
    end

    def refused(message) = Parsed.new(value: nil, error: message)
  end
end
