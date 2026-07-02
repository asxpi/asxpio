require_relative 'test_helper'

require_relative '../lib/crypto_asset'
require_relative '../lib/crypto_qr'

class CryptoAssetTest < Minitest::Test
  def test_registry_entries_are_complete
    CryptoAsset::ASSETS.each do |code, asset|
      assert asset[:name], "#{code} missing name"
      assert asset[:coingecko], "#{code} missing coingecko id"
    end
  end

  def test_valid_is_case_insensitive
    assert CryptoAsset.valid?('btc')
    assert CryptoAsset.valid?('usdt-trc20')
    refute CryptoAsset.valid?('DOGE')
  end

  def test_default_addresses_from_json_env
    ENV['CRYPTO_ADDRESSES'] = '{"BTC":"bc1qtest","usdt-trc20":"Ttest","DOGE":"ignored"}'
    map = CryptoAsset.default_addresses
    assert_equal 'bc1qtest', map['BTC']
    assert_equal 'Ttest', map['USDT-TRC20']
    refute map.key?('DOGE')
  ensure
    ENV.delete('CRYPTO_ADDRESSES')
  end

  def test_legacy_ltc_address_env_still_fills_ltc
    ENV['LTC_ADDRESS'] = 'ltc1legacy'
    assert_equal 'ltc1legacy', CryptoAsset.default_addresses['LTC']
  ensure
    ENV.delete('LTC_ADDRESS')
  end

  def test_default_addresses_survives_bad_json
    ENV['CRYPTO_ADDRESSES'] = 'not json'
    assert_equal({}, CryptoAsset.default_addresses)
  ensure
    ENV.delete('CRYPTO_ADDRESSES')
  end
end

class CryptoQrTest < Minitest::Test
  def test_bip21_uri_with_amount
    assert_equal 'bitcoin:bc1qaddr?amount=0.005',
                 CryptoQr.uri('BTC', 'bc1qaddr', BigDecimal('0.00500000'))
    assert_equal 'litecoin:ltc1qaddr?amount=1.25',
                 CryptoQr.uri('LTC', 'ltc1qaddr', BigDecimal('1.25'))
  end

  def test_monero_uses_tx_amount
    assert_equal 'monero:4Aaddr?tx_amount=2.5',
                 CryptoQr.uri('XMR', '4Aaddr', BigDecimal('2.5'))
  end

  def test_eth_scheme_without_amount
    assert_equal 'ethereum:0xAddr', CryptoQr.uri('ETH', '0xAddr', BigDecimal('1.5'))
  end

  def test_tokens_encode_bare_address
    assert_equal 'TAddr', CryptoQr.uri('USDT-TRC20', 'TAddr', BigDecimal('100'))
    assert_equal 'AAddr', CryptoQr.uri('USDC-ALGO', 'AAddr', nil)
  end

  def test_png_renders
    png = CryptoQr.png('BTC', 'bc1qexampleexampleexample', BigDecimal('0.01'))
    assert png.start_with?("\x89PNG".b)
  end
end
