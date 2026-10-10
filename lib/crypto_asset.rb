require 'json'

# Built-in crypto templates. Payout addresses (payout_addresses table) carry
# their own ticker, name, QR scheme, amount parameter and CoinGecko id; these
# entries only prefill those fields for a known ticker, back-fill rows from
# before that, and name legacy invoices. Nothing here limits which coins can
# be used.
#
# QR encoding is driven by scheme/amount_param:
#   scheme + amount_param  => scheme:<addr>?<param>=<amt>  (wallet prefills amount)
#   scheme only            => scheme:<addr>                (amount shown as text)
#   neither                => bare address                 (tokens/chains with no
#                                                           standard payment URI)
# coingecko is the id for the simple/price endpoint; chain variants of a
# stablecoin share the token's id.
module CryptoAsset
  DEFAULTS = {
    'BTC'        => { name: 'Bitcoin',              coingecko: 'bitcoin',  scheme: 'bitcoin',  amount_param: 'amount' },
    'LTC'        => { name: 'Litecoin',             coingecko: 'litecoin', scheme: 'litecoin', amount_param: 'amount' },
    'ETH'        => { name: 'Ethereum',             coingecko: 'ethereum', scheme: 'ethereum', amount_param: nil },
    'XMR'        => { name: 'Monero',               coingecko: 'monero',   scheme: 'monero',   amount_param: 'tx_amount' },
    'SOL'        => { name: 'Solana',               coingecko: 'solana',   scheme: 'solana',   amount_param: 'amount' },
    'ALGO'       => { name: 'Algorand',             coingecko: 'algorand', scheme: nil,        amount_param: nil },
    'USDT-ERC20' => { name: 'Tether (Ethereum)',    coingecko: 'tether',   scheme: nil,        amount_param: nil },
    'USDT-TRC20' => { name: 'Tether (Tron)',        coingecko: 'tether',   scheme: nil,        amount_param: nil },
    'USDT-BEP20' => { name: 'Tether (BNB Chain)',   coingecko: 'tether',   scheme: nil,        amount_param: nil },
    'USDT-SOL'   => { name: 'Tether (Solana)',      coingecko: 'tether',   scheme: nil,        amount_param: nil },
    'USDC-ERC20' => { name: 'USD Coin (Ethereum)',  coingecko: 'usd-coin', scheme: nil,        amount_param: nil },
    'USDC-BEP20' => { name: 'USD Coin (BNB Chain)', coingecko: 'usd-coin', scheme: nil,        amount_param: nil },
    'USDC-SOL'   => { name: 'USD Coin (Solana)',    coingecko: 'usd-coin', scheme: nil,        amount_param: nil },
    'USDC-ALGO'  => { name: 'USD Coin (Algorand)',  coingecko: 'usd-coin', scheme: nil,        amount_param: nil }
  }.freeze

  ASSETS = DEFAULTS # older name
  CODES  = DEFAULTS.keys.freeze

  TICKER_RE     = /\A[A-Z0-9][A-Z0-9-]{1,19}\z/
  SCHEME_RE     = /\A[a-z][a-z0-9+.-]{1,31}\z/
  AMOUNT_PARAMS = %w[amount tx_amount].freeze
  # Suggestions for the admin form; wallets only honour real URI schemes.
  KNOWN_SCHEMES = (DEFAULTS.values.filter_map { |a| a[:scheme] } +
                   %w[dogecoin bitcoincash dash zcash tron ton]).uniq.freeze

  module_function

  def [](code)
    ASSETS[code.to_s.upcase]
  end

  def valid?(code)
    ASSETS.key?(code.to_s.upcase)
  end

  def name(code)
    asset = self[code]
    asset ? asset[:name] : code.to_s
  end

  # Default payout addresses for the new-invoice form. CRYPTO_ADDRESSES is a
  # Legacy source, now only used to seed the payout_addresses table once
  # (PayoutAddress.seed_from_env!): CRYPTO_ADDRESSES is a JSON object
  # (code => address); LTC_ADDRESS still fills LTC. Unknown codes are
  # dropped so a typo in the env can't invent an asset.
  def env_addresses
    map = begin
      JSON.parse(ENV['CRYPTO_ADDRESSES'].to_s)
    rescue JSON::ParserError
      {}
    end
    map = {} unless map.is_a?(Hash)
    map = map.transform_keys { |k| k.to_s.upcase }
    ltc = ENV['LTC_ADDRESS'].to_s
    map['LTC'] = ltc unless ltc.empty? || map.key?('LTC')
    map.slice(*CODES)
  end
end
