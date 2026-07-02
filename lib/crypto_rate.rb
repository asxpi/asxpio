require 'net/http'
require 'json'
require 'uri'
require 'bigdecimal'
require_relative 'crypto_asset'

# Fetches the current price of a CryptoAsset from CoinGecko (free, no API key).
#
# CoinGecko's simple/price supports usd and eur directly. GEL is derived from
# the invoice's own captured gel_rate (USD->GEL): price_gel = price_usd * gel_rate.
module CryptoRate
  ENDPOINT = 'https://api.coingecko.com/api/v3/simple/price'.freeze
  SUPPORTED = %w[USD EUR].freeze
  TIMEOUT = 6 # seconds

  class Error < StandardError; end

  module_function

  # Returns a BigDecimal: the price of 1 unit of `coin` in `currency`.
  # `gel_rate` (USD->GEL) is required only when currency == 'GEL'.
  def fetch(coin, currency, gel_rate: nil)
    asset = CryptoAsset[coin] or raise Error, "Unknown coin: #{coin}"
    id = asset[:coingecko]
    currency = currency.to_s.upcase

    if currency == 'GEL'
      raise Error, 'gel_rate required to derive the GEL price' if gel_rate.nil?
      usd = fetch_simple(id, 'usd')
      (usd * BigDecimal(gel_rate.to_s)).round(8)
    elsif SUPPORTED.include?(currency)
      fetch_simple(id, currency.downcase).round(8)
    else
      raise Error, "Unsupported currency: #{currency}"
    end
  end

  def fetch_simple(id, vs)
    uri = URI(ENDPOINT)
    uri.query = URI.encode_www_form(ids: id, vs_currencies: vs)

    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                          open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
      http.get(uri.request_uri, 'Accept' => 'application/json')
    end

    raise Error, "CoinGecko HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

    data = JSON.parse(res.body)
    price = data.dig(id, vs)
    raise Error, "No price for #{id}/#{vs} in response" if price.nil?

    BigDecimal(price.to_s)
  rescue JSON::ParserError => e
    raise Error, "Bad JSON from CoinGecko: #{e.message}"
  rescue Net::OpenTimeout, Net::ReadTimeout
    raise Error, 'CoinGecko timed out'
  end
end
