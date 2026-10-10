require 'rqrcode'
require_relative 'crypto_asset'

# Renders a crypto payment QR as PNG bytes for embedding in the PDF.
# The payload follows the payout entry's scheme/amount parameter: a payment
# URI with amount, a bare scheme URI, or just the address.
module CryptoQr
  module_function

  # `amount` is a BigDecimal or nil (address-only QR).
  def uri(scheme:, amount_param:, address:, amount:)
    return address unless scheme
    base = "#{scheme}:#{address}"
    return base if amount.nil? || amount_param.nil?
    # Trim trailing zeros so the wallet shows a clean amount; keep up to 8 dp.
    amt = amount.round(8).to_s('F').sub(/\.?0+$/, '')
    "#{base}?#{amount_param}=#{amt}"
  end

  # Returns PNG bytes (binary string), sized for a crisp ~120pt PDF placement.
  def png(size: 480, **payload)
    qr = RQRCode::QRCode.new(uri(**payload), level: :m)
    qr.as_png(
      bit_depth:    1,
      border_modules: 2,
      color:        'black',
      fill:         'white',
      module_px_size: 6,
      resize_exactly_to: size
    ).to_s
  end
end
