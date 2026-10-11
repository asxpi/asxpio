ENV['RACK_ENV'] = 'test'

# Dummy env so the app class loads; nothing here reaches a real service.
ENV['SESSION_SECRET']  ||= 'test-secret-0000000000000000000000000000000000000000000000000000'
ENV['SMTP_ADDR']       ||= 'localhost'
ENV['SMTP_PORT']       ||= '587'
ENV['SMTP_USER']       ||= 'test'
ENV['SMTP_PASSWORD']   ||= 'test'
ENV['MAIL_FROM']       ||= 'Test <test@example.com>'
ENV['MAIL_TO']         ||= 'owner@example.com'
ENV['ADMIN_USER']      ||= 'admin'
ENV['ADMIN_PASSWORD']  ||= 'test-password'
ENV['SCRYPT_LOG_N']    ||= '10'    # cheap hashes in tests
ENV['LOGIN_RATE_LIMIT'] ||= '10000'

# DB-backed tests run only against an explicit test database (bin/test
# provisions an ephemeral one). Never fall through to a developer DATABASE_URL.
if ENV['TEST_DATABASE_URL']
  ENV['DATABASE_URL'] = ENV['TEST_DATABASE_URL']
  ENV['S3_ENDPOINT']        ||= 'http://127.0.0.1:1'
  ENV['S3_PUBLIC_ENDPOINT'] ||= 'http://127.0.0.1:1'
  ENV['S3_ACCESS_KEY']      ||= 'test'
  ENV['S3_SECRET_KEY']      ||= 'test'
  ENV['S3_BUCKET']          ||= 'test-bucket'
  require 'aws-sdk-s3'
  Aws.config[:s3] = { stub_responses: true } # no S3 call leaves the process
else
  ENV.delete('DATABASE_URL')
end

require_relative '../asxpio'
require 'minitest/autorun'
require 'rack/test'

Mail.defaults { delivery_method :test }

# Logs the rack-test session in through the real form (CSRF included).
# `admin_env` keeps the old call sites working: it logs in once per test
# and returns extra env to merge.
module AdminLogin
  def admin_login!(username: ENV['ADMIN_USER'], password: ENV['ADMIN_PASSWORD'])
    User[username: username] ||
      User.create(username: username, superuser: true, password: password)
    get '/admin/login'
    token = last_response.body[/name="authenticity_token" value="([^"]+)"/, 1]
    post '/admin/login', { authenticity_token: token, username: username, password: password }
    raise "login failed: #{last_response.status}" unless last_response.redirect?
    @admin_logged_in = true
  end

  def admin_env(extra = {})
    admin_login! unless @admin_logged_in
    extra
  end
end

module TestDb
  def self.available?
    !ENV['DATABASE_URL'].nil?
  end

  def self.clean!
    DB.connection[:invoices].delete
  end

  def self.clean_users!
    DB.connection[:users].delete
  end
end
