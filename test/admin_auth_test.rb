require_relative 'test_helper'

require 'base64'

class AdminAuthTest < Minitest::Test
  OK_APP = ->(_env) { [200, {}, ['ok']] }

  def setup
    @auth = AdminAuth.new(OK_APP)
  end

  def env_for(path, user: nil, pass: nil)
    env = { 'PATH_INFO' => path }
    if user
      env['HTTP_AUTHORIZATION'] = "Basic #{Base64.strict_encode64("#{user}:#{pass}")}"
    end
    env
  end

  def test_correct_credentials_pass
    assert_equal 200, @auth.call(env_for('/admin/invoices', user: 'admin', pass: 'test-password'))[0]
  end

  def test_wrong_password_rejected
    assert_equal 401, @auth.call(env_for('/admin/invoices', user: 'admin', pass: 'nope'))[0]
  end

  def test_wrong_user_rejected
    assert_equal 401, @auth.call(env_for('/admin/invoices', user: 'other', pass: 'test-password'))[0]
  end

  def test_missing_header_rejected
    assert_equal 401, @auth.call(env_for('/admin'))[0]
  end

  def test_sibling_paths_not_gated
    assert_equal 200, @auth.call(env_for('/'))[0]
    assert_equal 200, @auth.call(env_for('/admin-invoice-form.js'))[0]
  end
end
