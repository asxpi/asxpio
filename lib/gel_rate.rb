require 'net/http'
require 'json'
require 'uri'
require 'date'
require 'bigdecimal'

# Fetches the official GEL exchange rate from the National Bank of Georgia.
# https://nbg.gov.ge/en/monetary-policy/currency
#
# API: GET .../currencies/en/json/?currencies=USD&date=YYYY-MM-DD
# Response is a top-level array; rate is quoted per `quantity` units, so the
# per-unit rate is rate / quantity. NBG returns the rate valid on or before the
# requested date (weekends/holidays roll back to the last published rate).
module GelRate
  ENDPOINT = 'https://nbg.gov.ge/gw/api/ct/monetarypolicy/currencies/en/json/'.freeze
  TIMEOUT = 6 # seconds

  class Error < StandardError; end

  module_function

  # Returns a BigDecimal: how many GEL per 1 unit of `currency` on `date`.
  # `date` may be a Date or YYYY-MM-DD string; omitted ⇒ latest published rate.
  def fetch(currency = 'USD', date: nil)
    currency = currency.to_s.upcase
    uri = URI(ENDPOINT)
    query = { currencies: currency }
    query[:date] = normalize_date(date) if date
    uri.query = URI.encode_www_form(query)

    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                          open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
      http.get(uri.request_uri, 'Accept' => 'application/json')
    end
    raise Error, "NBG HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

    data = JSON.parse(res.body)
    entry = Array(data).first or raise Error, 'Empty NBG response'
    cur = Array(entry['currencies']).find { |c| c['code'] == currency } \
      or raise Error, "No #{currency} in NBG response"

    rate = BigDecimal(cur.fetch('rate').to_s)
    qty  = BigDecimal(cur.fetch('quantity', 1).to_s)
    raise Error, 'NBG quantity is zero' if qty.zero?

    (rate / qty).round(8)
  rescue JSON::ParserError => e
    raise Error, "Bad JSON from NBG: #{e.message}"
  rescue Net::OpenTimeout, Net::ReadTimeout
    raise Error, 'NBG timed out'
  rescue KeyError => e
    raise Error, "Missing field in NBG response: #{e.message}"
  end

  def normalize_date(date)
    d = date.is_a?(Date) ? date : Date.parse(date.to_s)
    d.strftime('%Y-%m-%d')
  rescue ArgumentError
    raise Error, "Invalid date: #{date}"
  end
end
