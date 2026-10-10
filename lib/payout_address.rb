require 'sequel'
require_relative 'crypto_asset'

# A crypto payout option, self-contained: ticker (`coin`, printed on the
# PDF), display name, QR URI scheme + amount parameter, CoinGecko id for the
# live rate, and the address. Several per ticker are fine (e.g. Ledger and
# exchange). The new-invoice form picks one; the invoice copies its fields
# (#snapshot), so editing or retiring an entry never changes issued invoices.
class PayoutAddress < Sequel::Model(:payout_addresses)
  ADDRESS_RE = /\A[a-zA-Z0-9]{10,128}\z/ # loose shape check, same as invoices
  FIELDS     = %i[name coin scheme amount_param coingecko address].freeze

  def self.listing
    order(Sequel.desc(:active), :coin, :name, :id).all
  end

  def self.active_list
    where(active: true).order(:coin, :name, :id).all
  end

  # First boot after moving off env: import CRYPTO_ADDRESSES / LTC_ADDRESS.
  def self.seed_from_env!
    return if count.positive?
    CryptoAsset.env_addresses.each do |coin, address|
      next unless address.match?(ADDRESS_RE)
      create(**template(coin), coin: coin, address: address, updated_by: 'env import', updated_at: Time.now.utc)
    end
  end

  # Known ticker → its usual name/scheme/amount param/CoinGecko id.
  def self.template(coin)
    a = CryptoAsset::DEFAULTS[coin.to_s.upcase] or return {}
    { name: a[:name], scheme: a[:scheme], amount_param: a[:amount_param], coingecko: a[:coingecko] }
  end

  # Cleans form input: blanks → nil, scheme lowercased without a trailing
  # colon, ticker uppercased; empty optional fields are taken from the
  # template when the ticker is a known one.
  def self.clean(raw, fill_from_template: false)
    v = FIELDS.to_h { |f| [f, raw[f.to_s].to_s.strip.then { |x| x.empty? ? nil : x }] }
    v[:coin]      = v[:coin]&.upcase
    v[:scheme]    = v[:scheme]&.downcase&.delete_suffix(':')
    v[:coingecko] = v[:coingecko]&.downcase
    if fill_from_template
      template(v[:coin]).each { |k, t| v[k] ||= t }
    end
    v[:name] ||= v[:coin]
    v
  end

  def self.error_for(v)
    label = v[:coin] || 'new entry'
    return "#{label}: ticker must be A–Z, 0–9 and -, 2–20 characters" unless v[:coin].to_s.match?(CryptoAsset::TICKER_RE)
    return "#{label}: address looks invalid" unless v[:address].to_s.match?(ADDRESS_RE)
    return "#{label}: scheme must look like 'litecoin' (full coin name, lowercase)" if v[:scheme] && !v[:scheme].match?(CryptoAsset::SCHEME_RE)
    return "#{label}: unknown amount parameter" if v[:amount_param] && !CryptoAsset::AMOUNT_PARAMS.include?(v[:amount_param])
    return "#{label}: amount in QR needs a scheme" if v[:amount_param] && !v[:scheme]
    return "#{label}: CoinGecko id looks invalid" if v[:coingecko] && !v[:coingecko].match?(/\A[a-z0-9-]{2,64}\z/)
    nil
  end

  # What an invoice copies at issue (Invoice.build reads these params).
  def snapshot
    { crypto_coin: coin, crypto_address: address, crypto_name: name,
      crypto_scheme: scheme, crypto_amount_param: amount_param }
  end

  def option_label
    "#{name} · #{coin} · #{address[0, 10]}…"
  end
end
