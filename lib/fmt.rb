require 'bigdecimal'

# Number formatting shared by the HTML views and the PDF so they can't drift.
module Fmt
  module_function

  # Exchange rate: full captured precision (up to 8 dp), trailing zeros
  # trimmed, padded to at least min_dp so it reads as a rate. (4 dp matches
  # the NBG's GEL quoting.)
  def rate(value, min_dp: 4)
    int, frac = BigDecimal(value.to_s).round(8).to_s('F').split('.')
    frac = (frac || '').sub(/0+$/, '').ljust(min_dp, '0')
    "#{group(int)}.#{frac}"
  end

  # LTC amount: up to 8 dp, trailing zeros trimmed, no padding.
  def ltc(value)
    BigDecimal(value.to_s).round(8).to_s('F').sub(/(\.\d*?)0+$/, '\1').sub(/\.$/, '')
  end

  # "1234567" -> "1,234,567"
  def group(int)
    int.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse
  end
end
