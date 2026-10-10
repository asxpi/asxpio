require_relative 'test_helper'

class AdminAuthTest < Minitest::Test
  include Rack::Test::Methods
  include AdminLogin

  def app
    AsxpioWeb
  end

  def setup
    skip 'TEST_DATABASE_URL not set' unless TestDb.available?
    TestDb.clean_users!
  end

  def login(username, password)
    get '/admin/login'
    token = last_response.body[/name="authenticity_token" value="([^"]+)"/, 1]
    post '/admin/login', { authenticity_token: token, username: username, password: password }
  end

  def test_password_hashing
    d = User.hash_password('correct horse')
    assert_match(/\Ascrypt\$\d+\$8\$1\$/, d)
    assert User.verify_password('correct horse', d)
    refute User.verify_password('wrong', d)
    refute_equal d, User.hash_password('correct horse') # salted
  end

  def test_bootstrap_only_once
    User.bootstrap!('Boss', 'first-password-1')
    assert User[username: 'boss'].superuser
    User.bootstrap!('other', 'x' * 12)
    assert_equal 1, User.count
  end

  def test_login_and_logout
    User.create(username: 'alice', superuser: true, password: 'alice-password-1')
    login('alice', 'alice-password-1')
    assert_equal 302, last_response.status
    get '/admin'
    assert last_response.ok?
    assert_includes last_response.body, 'alice'
    get '/admin'
    token = last_response.body[/name="authenticity_token" value="([^"]+)"/, 1]
    post '/admin/logout', { authenticity_token: token }
    get '/admin'
    assert_equal 302, last_response.status
  end

  def test_wrong_password_and_unknown_user
    User.create(username: 'alice', superuser: true, password: 'alice-password-1')
    login('alice', 'nope')
    assert_equal 401, last_response.status
    login('mallory', 'alice-password-1')
    assert_equal 401, last_response.status
  end

  def test_inactive_user_cannot_log_in
    User.create(username: 'alice', superuser: true, active: false, password: 'alice-password-1')
    User.create(username: 'root', superuser: true, password: 'root-password-11')
    login('alice', 'alice-password-1')
    assert_equal 401, last_response.status
  end

  def test_env_credentials_only_without_active_superuser
    User.create(username: 'alice', superuser: true, password: 'alice-password-1')
    login(ENV['ADMIN_USER'], ENV['ADMIN_PASSWORD'])
    assert_equal 401, last_response.status            # dormant: alice exists

    User[username: 'alice'].update(active: false)
    login(ENV['ADMIN_USER'], ENV['ADMIN_PASSWORD'])
    assert_equal 302, last_response.status            # recovery
    assert User[username: ENV['ADMIN_USER']].superuser
  end

  def test_session_revoked_by_version_bump
    u = User.create(username: 'alice', superuser: true, password: 'alice-password-1')
    login('alice', 'alice-password-1')
    get '/admin'
    assert last_response.ok?
    u.logout_everywhere!
    get '/admin'
    assert_equal 302, last_response.status
  end

  def test_non_superuser_limited_to_open_pages_in_phase_one
    User.create(username: 'bob', password: 'bob-password-12')
    login('bob', 'bob-password-12')
    get '/admin'
    assert last_response.ok?
    get '/admin/account/password'
    assert last_response.ok?
    get '/admin/invoices'
    assert_equal 403, last_response.status
  end

  def test_must_change_password_flow
    User.create(username: 'alice', superuser: true, must_change_password: true, password: 'temporary-pass-1')
    login('alice', 'temporary-pass-1')
    get '/admin/invoices'
    assert_equal '/admin/account/password', URI(last_response.location).path
    get '/admin/account/password'
    token = last_response.body[/name="authenticity_token" value="([^"]+)"/, 1]
    post '/admin/account/password', { authenticity_token: token, current: 'temporary-pass-1', password: 'short', confirm: 'short' }
    assert_equal 422, last_response.status
    post '/admin/account/password', { authenticity_token: token, current: 'temporary-pass-1',
                                      password: 'brand-new-pass-1', confirm: 'brand-new-pass-1' }
    assert_equal 302, last_response.status
    refute User[username: 'alice'].must_change_password
    assert User[username: 'alice'].authenticate('brand-new-pass-1')
  end

  def test_next_param_is_restricted_to_admin
    User.create(username: 'alice', superuser: true, password: 'alice-password-1')
    get '/admin/login?next=https://evil.example/'
    token = last_response.body[/name="authenticity_token" value="([^"]+)"/, 1]
    post '/admin/login', { authenticity_token: token, username: 'alice', password: 'alice-password-1', next: 'https://evil.example/' }
    assert_equal '/admin', URI(last_response.location).path
  end

  def test_login_rate_limited
    AdminAuth.login_limit = RateLimit.new(limit: 2, window: 900)
    3.times { login('x', 'y') }
    assert_equal 429, last_response.status
  ensure
    AdminAuth.login_limit = nil
  end
end
