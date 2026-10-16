# frozen_string_literal: true

module Briefs
  # Reads the wizard's form values. Blank is nil (a draft may leave a field empty); a value that is
  # present but not a number is an ERROR, never a silent 0 ("abc".to_i is 0, the F-17 lesson).
  class Params
    def initialize(hash)
      @hash = hash
    end

    def key?(key) = @hash.key?(key)

    def text(key) = @hash[key].to_s.strip.presence

    def boolean(key) = ActiveModel::Type::Boolean.new.cast(@hash[key]) || false

    def choice(key, options) = options.key?(@hash[key]) ? @hash[key] : nil

    def section(key) = @hash[key].is_a?(Hash) ? @hash[key] : {}

    # Distinct non-blank entries, in the order typed.
    def list(key) = Array(@hash[key]).map { |v| v.to_s.strip }.reject(&:empty?).uniq

    # Slots of a repeating section ("0" => {...}, "1" => {...}) in slot order.
    def rows(key)
      value = @hash[key]
      value = value.sort_by { |k, _| k.to_i }.map(&:last) if value.is_a?(Hash)
      Array(value).select { |row| row.is_a?(Hash) }
    end

    def integer(key, errors, label) = integer_value(@hash[key], errors, label)

    # Storage limits, not business rules: an integer column holds at most INT_MAX, a bigint
    # (salary) at most BIGINT_MAX. Without these a long string of digits reached the model as an
    # ActiveModel::RangeError and an error page (test engine F-01).
    INT_MAX = 2_147_483_647
    BIGINT_MAX = 9_223_372_036_854_775_807

    def integer_value(value, errors, label)
      text = value.to_s.strip
      return if text.empty?
      return bounded(text.to_i, INT_MAX, errors, label) if text.match?(/\A\d+\z/)

      errors << "#{label} must be a whole number without a sign, for example 20."
      nil
    end

    # Integer rupiah. Accepts the house display form ("Rp5.200.000", "5.200.000", "5200000").
    # A decimal comma is refused: salaries are whole rupiah (blueprint §2.1).
    def rupiah(key, errors, label)
      text = @hash[key].to_s.strip.sub(/\ARp\s*/i, "").delete(" ")
      return if text.empty?
      return bounded(text.delete(".").to_i, BIGINT_MAX, errors, label) if text.match?(/\A\d{1,3}(\.\d{3})*\z|\A\d+\z/)

      errors << "#{label} must be a whole rupiah amount, for example 5.200.000."
      nil
    end

    def bounded(number, max, errors, label)
      return number if number <= max

      errors << "#{label} is too large; check the figure again."
      nil
    end

    # A threshold with at most one decimal; comma or point (Indonesian or English typing).
    def decimal_value(value, errors, label)
      text = value.to_s.strip.tr(",", ".")
      return if text.empty?
      return text.to_f.round(1) if text.match?(/\A\d+(\.\d)?\z/)

      errors << "#{label} must be a number with at most one decimal, for example 62,5."
      nil
    end
  end
end
