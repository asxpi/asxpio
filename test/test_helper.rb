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

module TestDb
  def self.available?
    !ENV['DATABASE_URL'].nil?
  end

  def self.clean!
    DB.connection[:invoices].delete
  end
end
