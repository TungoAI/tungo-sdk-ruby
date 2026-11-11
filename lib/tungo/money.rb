# frozen_string_literal: true

module Tungo
  # Money helpers. The API expresses amounts in tiyn (1/100 of a tenge) as 64-bit integers.
  # Conversion is exact: no binary floating point is involved for String, Integer, BigDecimal
  # and Rational input.
  module Money
    INT64 = (-(2**63)..((2**63) - 1))
    DECIMAL = /\A(-?)([0-9]+)(?:\.([0-9]+))?\z/
    SYMBOLS = { "" => "₸", "KZT" => "₸", "USD" => "$", "EUR" => "€", "RUB" => "₽" }.freeze
    BIN_IIN = /\A[0-9]{12}\z/
    private_constant :DECIMAL, :SYMBOLS, :BIN_IIN

    module_function

    # Converts an amount in tenge to tiyn, rounding half away from zero to two decimal places.
    #
    #   Tungo::Money.to_tiyn("1.005")             # => 101
    #   Tungo::Money.to_tiyn(BigDecimal("45000")) # => 4_500_000
    #
    # @param amount [String, Integer, BigDecimal, Rational, Float] a String must match
    #   +-?digits[.digits]+; a Float is converted through its shortest decimal representation
    # @return [Integer] tiyn, within int64
    # @raise [Tungo::MoneyError] malformed, non-finite or out-of-range input
    def to_tiyn(amount)
      tiyn = case amount
             when String then decimal_to_tiyn(amount)
             when Integer then amount * 100
             when BigDecimal, Float then decimal_to_tiyn(finite_decimal(amount).to_s("F"))
             when Rational then rational_to_tiyn(amount)
             else raise MoneyError, "cannot convert #{amount.class} to tiyn"
             end
      check_range(tiyn)
    end

    # @param tiyn [Integer]
    # @return [BigDecimal] the exact amount in tenge
    def to_tenge(tiyn)
      BigDecimal(check_integer(tiyn)) / 100
    end

    # Formats tiyn for display: +4500000+ becomes "45 000,00 ₸".
    #
    # @param tiyn [Integer]
    # @param currency [String] ISO code; KZT, USD, EUR and RUB get their symbol, others the code
    # @return [String]
    def format_tiyn(tiyn, currency = "KZT")
      tiyn = check_range(check_integer(tiyn))
      code = currency.to_s.upcase
      whole, fraction = tiyn.abs.divmod(100)
      grouped = whole.to_s.reverse.scan(/[0-9]{1,3}/).join(" ").reverse
      "#{"-" if tiyn.negative?}#{grouped},#{fraction.to_s.rjust(2, "0")} #{SYMBOLS.fetch(code, code)}"
    end

    # Checks a Kazakhstan BIN/IIN: exactly 12 ASCII digits with a valid check digit. The input
    # is not trimmed.
    #
    # @param value [String]
    # @return [Boolean]
    def valid_bin_iin?(value)
      return false unless value.is_a?(String) && BIN_IIN.match?(value)

      digits = value.bytes.map { |byte| byte - 48 }
      check = bin_iin_checksum(digits, 1)
      check = bin_iin_checksum(digits, 3) if check == 10
      check < 10 && check == digits[11]
    end

    # @api private
    def decimal_to_tiyn(text)
      match = text.encoding.ascii_compatible? ? DECIMAL.match(text) : nil
      raise MoneyError, "#{text.inspect} is not a decimal amount (expected -?digits[.digits])" unless match

      fraction = "#{match[3]}000"
      tiyn = "#{match[2]}#{fraction[0, 2]}".to_i
      tiyn += 1 if fraction[2] >= "5"
      match[1] == "-" ? -tiyn : tiyn
    end

    # @api private
    def rational_to_tiyn(amount)
      tiyn = ((amount.abs * 100) + Rational(1, 2)).floor
      amount.negative? ? -tiyn : tiyn
    end

    # @api private
    def finite_decimal(amount)
      raise MoneyError, "#{amount} is not a finite amount" unless amount.finite?

      amount.is_a?(Float) ? BigDecimal(amount.to_s) : amount
    end

    # @api private
    def check_integer(tiyn)
      raise MoneyError, "tiyn must be an Integer, got #{tiyn.class}" unless tiyn.is_a?(Integer)

      tiyn
    end

    # @api private
    def check_range(tiyn)
      raise MoneyError, "#{tiyn} tiyn does not fit into a 64-bit integer" unless INT64.cover?(tiyn)

      tiyn
    end

    # @api private
    def bin_iin_checksum(digits, first_weight)
      (0...11).sum { |index| digits[index] * (((first_weight - 1 + index) % 11) + 1) } % 11
    end
  end
end
