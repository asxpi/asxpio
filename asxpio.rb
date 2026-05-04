require 'logger'
require 'sinatra/base'
require 'sinatra/contrib'
require 'erubi'
require 'uri'

begin
  require 'dotenv'
  Dotenv.load
rescue LoadError
end

require_relative 'lib/mailer'
require_relative 'lib/rate_limit'

$root   = __dir__
$logger = Logger.new($stdout)
$env    = ENV.fetch('RACK_ENV', 'development')

class AsxpioWeb < Sinatra::Base
  RATE_LIMIT = RateLimit.new(limit: 5, window: 3600)

  configure do
    set :root, $root
    set :erb, layout: :layout, escape_html: true
    set :show_exceptions, $env == 'development'
    set :host_authorization, { permitted_hosts: [] }
  end

  use Rack::Session::Cookie,
      key:          'asxpio.session',
      path:         '/',
      secret:       ENV.fetch('SESSION_SECRET'),
      expire_after: 3600,
      same_site:    :lax

  use Rack::Protection::AuthenticityToken

  Mailer.configure!

  helpers do
    def csrf_token
      Rack::Protection::AuthenticityToken.token(session)
    end

    def client_ip
      request.env['HTTP_X_FORWARDED_FOR']&.split(',')&.first&.strip ||
        request.env['HTTP_X_REAL_IP'] ||
        request.ip
    end
  end

  before do
    cache_control :private, :must_revalidate, max_age: 0
  end

  get '/' do
    @form_errors = nil
    @form_values = {}
    erb :index
  end

  post '/contact' do
    name    = params[:name].to_s.strip
    email   = params[:email].to_s.strip
    subject = params[:subject].to_s.strip
    message = params[:message].to_s.strip
    honey   = params[:website].to_s

    # Honeypot — silently pretend success
    redirect '/thanks' unless honey.empty?

    @form_values = { name: name, email: email, subject: subject, message: message }
    @form_errors = {}

    @form_errors[:name]    = 'Required (1–100 chars)'  if name.empty? || name.length > 100
    @form_errors[:email]   = 'Valid email required'    if email.empty? || email !~ URI::MailTo::EMAIL_REGEXP || email.length > 200
    @form_errors[:subject] = 'Max 200 chars'            if subject.length > 200
    @form_errors[:message] = 'Required (1–5000 chars)' if message.empty? || message.length > 5000

    if @form_errors.any?
      status 422
      return erb :index
    end

    unless RATE_LIMIT.allow?(client_ip)
      @form_errors[:base] = 'Too many submissions. Try again later or email ie@asxp.io directly.'
      status 429
      return erb :index
    end

    begin
      Mailer.notify_owner(
        name: name, email: email, subject: subject, message: message, ip: client_ip
      )
    rescue StandardError => e
      $logger.error("notify_owner failed: #{e.class}: #{e.message}")
      @form_errors[:base] = 'Could not send message right now. Please email ie@asxp.io directly.'
      status 500
      return erb :index
    end

    begin
      Mailer.confirm_visitor(name: name, email: email, subject: subject, message: message)
    rescue StandardError => e
      $logger.warn("confirm_visitor failed: #{e.class}: #{e.message}")
    end

    redirect '/thanks'
  end

  get '/thanks' do
    @page_title = 'Thanks — IE Sergei Poljanski'
    @page_desc  = 'Your message has been received. A confirmation copy has been sent to your inbox.'
    @noindex    = true
    erb :thanks
  end

  error 403 do
    'Forbidden — likely CSRF token expired. Reload the page and try again.'
  end
end
