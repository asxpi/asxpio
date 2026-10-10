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

  def token
    get '/admin/invoices/payout-addresses'
    last_response.body[/name="authenticity_token" value="([^"]+)"/, 1]
  end

  def test_seed_from_env_once
    ENV['CRYPTO_ADDRESSES'] = '{"BTC":"bc1qseedseedseedseed","XYZ":"nope00000000"}'
    PayoutAddress.seed_from_env!
    assert_equal({ 'BTC' => 'bc1qseedseedseedseed' }, PayoutAddress.map)
    ENV['CRYPTO_ADDRESSES'] = '{"BTC":"bc1qotherotherother"}'
    PayoutAddress.seed_from_env!
    assert_equal 'bc1qseedseedseedseed', PayoutAddress.map['BTC'] # not re-seeded
  ensure
    ENV.delete('CRYPTO_ADDRESSES')
  end

  def test_admin_edits_validates_and_removes
    admin_login!
    post '/admin/invoices/payout-addresses', { authenticity_token: token, address: { 'LTC' => 'ltc1qaaaaaaaaaaaaaaaa', 'BTC' => 'bad addr!' } }
    assert_equal 302, last_response.status
    assert_equal 'ltc1qaaaaaaaaaaaaaaaa', PayoutAddress.map['LTC']
    assert_nil PayoutAddress.map['BTC']
    get '/admin/invoices/payout-addresses'
    assert_includes last_response.body, 'BTC: address looks invalid'
    assert_includes DB.connection[:audit_log].select_map(:action), 'invoice.payout_addresses'

    get '/admin/invoices/new'
    assert_includes last_response.body, 'ltc1qaaaaaaaaaaaaaaaa'      # prefilled from DB

    post '/admin/invoices/payout-addresses', { authenticity_token: token, address: { 'LTC' => '' } }
    assert_nil PayoutAddress.map['LTC']
  end

  def test_read_only_user_sees_disabled_form
    u = User.create(username: 'reader', password: 'reader-password1')
    UserPermission.create(user_id: u.id, area: 'invoices', can_read: true)
    admin_login!(username: 'reader', password: 'reader-password1')
    get '/admin/invoices/payout-addresses'
    assert last_response.ok?
    assert_includes last_response.body, 'disabled'
    refute_includes last_response.body, 'Save addresses'
    post '/admin/invoices/payout-addresses', { authenticity_token: token, address: { 'LTC' => 'ltc1qbbbbbbbbbbbbbbbb' } }
    assert_equal 403, last_response.status
  end
end
