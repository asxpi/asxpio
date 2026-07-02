require_relative 'test_helper'

class FmtTest < Minitest::Test
  def test_rate_pads_to_min_dp
    assert_equal '2.9500', Fmt.rate('2.95')
    assert_equal '3.0000', Fmt.rate(3)
  end

  def test_rate_keeps_captured_precision
    assert_equal '2.95123456', Fmt.rate('2.95123456')
  end

  def test_rate_groups_thousands
    assert_equal '1,050.2500', Fmt.rate('1050.25')
  end

  def test_crypto_trims_trailing_zeros
    assert_equal '1.25', Fmt.crypto('1.250000')
    assert_equal '2', Fmt.crypto('2.0')
    assert_equal '0.00123456', Fmt.crypto('0.00123456')
  end
end
