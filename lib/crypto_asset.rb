require 'json'

# Registry of crypto payment assets — one asset (coin, or token+chain for
# stablecoins) per invoice. Adding an asset is one entry here plus, optionally,
# a default payout address in the CRYPTO_ADDRESSES env (JSON, code => address).
#
# QR encoding is driven by scheme/amount_param:
#   scheme + amount_param  => scheme:<addr>?<param>=<amt>  (wallet prefills amount)
#   scheme only            => scheme:<addr>                (amount shown as text)
#   neither                => bare address                 (tokens/chains with no
#                                                           standard payment URI)
# coingecko is the id for the simple/price endpoint; chain variants of a
# stablecoin share the token's id.
module CryptoAsset
  ASSETS = {
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

  CODES = ASSETS.keys.freeze

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
  # JSON object (code => address); the legacy LTC_ADDRESS env still fills LTC.
  # Unknown codes are dropped so a typo in the env can't invent an asset.
  def default_addresses
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
