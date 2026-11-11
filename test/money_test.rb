# frozen_string_literal: true

require_relative "test_helper"

class MoneyTest < TungoTestCase
  def test_accepted_input_types
    assert_equal 101, Tungo::Money.to_tiyn("1.005")
    assert_equal 101, Tungo::Money.to_tiyn(BigDecimal("1.005"))
    assert_equal 101, Tungo::Money.to_tiyn(Rational(1005, 1000))
    assert_equal 101, Tungo::Money.to_tiyn(1.005)
    assert_equal 4_500_000, Tungo::Money.to_tiyn(45_000)
    assert_equal(-101, Tungo::Money.to_tiyn("-1.005"))
  end

  def test_no_binary_float_arithmetic
    assert_equal 833, Tungo::Money.to_tiyn("8.325")
    assert_equal 29, Tungo::Money.to_tiyn(0.285)
    assert_equal 100_000_000_000_000_001, Tungo::Money.to_tiyn("1000000000000000.01")
  end

  def test_invalid_input_raises_money_error
    ["", " 1", "1,5", "1e3", "abc", "١٢", nil, :one, [1], BigDecimal("NaN"), BigDecimal("Infinity"),
     "92233720368547758.08"].each do |input|
      assert_raises(Tungo::MoneyError, input.inspect) { Tungo::Money.to_tiyn(input) }
    end
    assert_kind_of Tungo::ValidationError, assert_raises(Tungo::MoneyError) { Tungo::Money.format_tiyn(1.5) }
    assert_raises(Tungo::MoneyError) { Tungo::Money.format_tiyn("100") }
  end

  def test_to_tenge_is_a_big_decimal
    tenge = Tungo::Money.to_tenge(4_500_050)

    assert_instance_of BigDecimal, tenge
    assert_equal BigDecimal("45000.5"), tenge
    assert_equal 4_500_050, Tungo::Money.to_tiyn(tenge)
  end

  def test_format
    assert_equal "45 000,00 ₸", Tungo::Money.format_tiyn(4_500_000)
    assert_equal "-0,50 $", Tungo::Money.format_tiyn(-50, "USD")
    assert_equal "1 234,56 GBP", Tungo::Money.format_tiyn(123_456, "gbp")
  end

  def test_bin_iin_rejects_non_strings
    refute Tungo::Money.valid_bin_iin?(nil)
    refute Tungo::Money.valid_bin_iin?(990_140_000_017)
    refute Tungo::Money.valid_bin_iin?(" 000000000000")
  end
end
