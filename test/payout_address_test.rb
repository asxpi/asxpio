require_relative 'test_helper'

class PayoutAddressTest < Minitest::Test
  include Rack::Test::Methods
  include AdminLogin

  def app
    AsxpioWeb
  end

  def setup
    skip 'TEST_DATABASE_URL not set' unless TestDb.available?
    TestDb.clean_users!
    DB.connection[:payout_addresses].delete
  end

  def token(path = '/admin/invoices/payout-addresses')
    get path
    last_response.body[/name="authenticity_token" value="([^"]+)"/, 1]
  end

  def add(fields)
    post '/admin/invoices/payout-addresses', { authenticity_token: token, payout: { 'new' => fields } }
  end

  def test_seed_from_env_once
    ENV['CRYPTO_ADDRESSES'] = '{"BTC":"bc1qseedseedseedseed","XYZ":"nope00000000"}'
    PayoutAddress.seed_from_env!
    rows = PayoutAddress.all
    assert_equal [['BTC', 'bc1qseedseedseedseed', 'Bitcoin', 'bitcoin']], rows.map { |r| [r.coin, r.address, r.name, r.scheme] }
    ENV['CRYPTO_ADDRESSES'] = '{"BTC":"bc1qotherotherother"}'
    PayoutAddress.seed_from_env!
    assert_equal 1, PayoutAddress.count
  ensure
    ENV.delete('CRYPTO_ADDRESSES')
  end

  def test_add_known_ticker_fills_from_template_and_custom_coin
    admin_login!
    add('coin' => 'ltc', 'address' => 'ltc1qaaaaaaaaaaaaaaaa', 'name' => 'Litecoin (Ledger)')
    add('coin' => 'LTC', 'address' => 'ltc1qbbbbbbbbbbbbbbbb', 'name' => 'Litecoin (Exchange)')
    add('coin' => 'DOGE', 'address' => 'DAddr1234567890', 'name' => 'Dogecoin', 'scheme' => 'dogecoin:', 'amount_param' => 'amount', 'coingecko' => 'dogecoin')
    add('coin' => 'BTC', 'address' => 'bad addr!')
    led = PayoutAddress[address: 'ltc1qaaaaaaaaaaaaaaaa']
    assert_equal ['LTC', 'litecoin', 'amount', 'litecoin'], [led.coin, led.scheme, led.amount_param, led.coingecko]
    assert_equal 2, PayoutAddress.where(coin: 'LTC').count
    doge = PayoutAddress[coin: 'DOGE']
    assert_equal 'dogecoin', doge.scheme                                   # colon stripped
    get '/admin/invoices/payout-addresses'
    assert_includes last_response.body, 'BTC: address looks invalid'
    assert_includes last_response.body, 'QR → dogecoin:DAddr1234567890?amount=0.5'

    get '/admin/invoices/new'
    assert_includes last_response.body, 'Litecoin (Exchange) · LTC'
    assert_includes last_response.body, 'Dogecoin · DOGE'
  end

  def test_edit_validate_retire_and_remove
    admin_login!
    add('coin' => 'LTC', 'address' => 'ltc1qaaaaaaaaaaaaaaaa')
    row = PayoutAddress.first
    post '/admin/invoices/payout-addresses', { authenticity_token: token,
      payout: { row.id.to_s => { 'coin' => 'LTC', 'name' => 'Main', 'address' => row.address, 'scheme' => 'Lite Coin', 'active' => '1' } } }
    assert_equal 'Litecoin', row.refresh.name                              # bad scheme: nothing saved
    get '/admin/invoices/payout-addresses'
    assert_includes last_response.body, "scheme must look like"

    post '/admin/invoices/payout-addresses', { authenticity_token: token,
      payout: { row.id.to_s => { 'coin' => 'LTC', 'name' => 'Main', 'address' => row.address, 'scheme' => 'litecoin', 'amount_param' => 'amount' } } } # active unticked
    row.refresh
    assert_equal 'Main', row.name
    refute row.active
    get '/admin/invoices/new'
    refute_includes last_response.body, 'Main · LTC'                       # retired: not offered

    post "/admin/invoices/payout-addresses/#{row.id}/delete", { authenticity_token: token }
    assert_nil PayoutAddress[row.id]
    assert_includes DB.connection[:audit_log].select_map(:action), 'invoice.payout_address_delete'
  end

  def test_rate_endpoint_uses_payout_coingecko_id
    admin_login!
    add('coin' => 'XYZ', 'address' => 'XYZaddress1234567')                # custom coin, no CoinGecko id
    get "/admin/crypto-rate?payout=#{PayoutAddress.first.id}&currency=EUR"
    assert_equal 502, last_response.status
    assert_includes last_response.body, 'enter the rate by hand'
  end

  def test_read_only_user_sees_disabled_form
    u = User.create(username: 'reader', password: 'reader-password1')
    UserPermission.create(user_id: u.id, area: 'invoices', can_read: true)
    admin_login!(username: 'reader', password: 'reader-password1')
    get '/admin/invoices/payout-addresses'
    assert last_response.ok?
    refute_includes last_response.body, '>Save</button>'
    add('coin' => 'LTC', 'address' => 'ltc1qbbbbbbbbbbbbbbbb')
    assert_equal 403, last_response.status
  end

end
