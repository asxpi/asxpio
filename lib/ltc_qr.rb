require 'rqrcode'

# Renders a Litecoin payment QR as PNG bytes for embedding in the PDF.
# Encodes a BIP21-style URI: litecoin:<address>?amount=<ltc>
module LtcQr
  module_function

  # `amount` is a BigDecimal LTC amount or nil (address-only QR).
  def uri(address, amount)
    base = "litecoin:#{address}"
    return base if amount.nil?
    # Trim trailing zeros so the wallet shows a clean amount; keep up to 8 dp.
    amt = amount.round(8).to_s('F').sub(/\.?0+$/, '')
    "#{base}?amount=#{amt}"
  end

  # Returns PNG bytes (binary string), sized for a crisp ~120pt PDF placement.
  def png(address, amount, size: 480)
    data = uri(address, amount)
    qr = RQRCode::QRCode.new(data, level: :m)
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
