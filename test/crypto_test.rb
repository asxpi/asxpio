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

  def test_env_addresses_from_json_env
    ENV['CRYPTO_ADDRESSES'] = '{"BTC":"bc1qtest","usdt-trc20":"Ttest","DOGE":"ignored"}'
    map = CryptoAsset.env_addresses
    assert_equal 'bc1qtest', map['BTC']
    assert_equal 'Ttest', map['USDT-TRC20']
    refute map.key?('DOGE')
  ensure
    ENV.delete('CRYPTO_ADDRESSES')
  end

  def test_legacy_ltc_address_env_still_fills_ltc
    ENV['LTC_ADDRESS'] = 'ltc1legacy'
    assert_equal 'ltc1legacy', CryptoAsset.env_addresses['LTC']
  ensure
    ENV.delete('LTC_ADDRESS')
  end

  def test_env_addresses_survives_bad_json
    ENV['CRYPTO_ADDRESSES'] = 'not json'
    assert_equal({}, CryptoAsset.env_addresses)
  ensure
    ENV.delete('CRYPTO_ADDRESSES')
  end
end

class CryptoQrTest < Minitest::Test
  def uri(scheme, amount_param, address, amount)
    CryptoQr.uri(scheme: scheme, amount_param: amount_param, address: address, amount: amount)
  end

  def test_bip21_uri_with_amount
    assert_equal 'bitcoin:bc1qaddr?amount=0.005', uri('bitcoin', 'amount', 'bc1qaddr', BigDecimal('0.00500000'))
    assert_equal 'litecoin:ltc1qaddr?amount=1.25', uri('litecoin', 'amount', 'ltc1qaddr', BigDecimal('1.25'))
  end

  def test_monero_uses_tx_amount
    assert_equal 'monero:4Aaddr?tx_amount=2.5', uri('monero', 'tx_amount', '4Aaddr', BigDecimal('2.5'))
  end

  def test_scheme_without_amount_param
    assert_equal 'ethereum:0xAddr', uri('ethereum', nil, '0xAddr', BigDecimal('1.5'))
  end

  def test_no_scheme_encodes_bare_address
    assert_equal 'TAddr', uri(nil, nil, 'TAddr', BigDecimal('100'))
    assert_equal 'AAddr', uri(nil, nil, 'AAddr', nil)
  end

  def test_png_renders
    png = CryptoQr.png(scheme: 'bitcoin', amount_param: 'amount', address: 'bc1qexampleexampleexample', amount: BigDecimal('0.01'))
    assert png.start_with?("\x89PNG".b)
  end
end
