require 'logger'
require 'bigdecimal'
require 'sinatra/base'
require 'sinatra/contrib'
require 'erubi'
require 'uri'

begin
  require 'dotenv'
  Dotenv.load
rescue LoadError
end

$root   = __dir__
$logger = Logger.new($stdout)
$env    = ENV.fetch('RACK_ENV', 'development')

require_relative 'lib/mailer'
require_relative 'lib/rate_limit'
require_relative 'lib/db'
require_relative 'lib/admin_auth'
require_relative 'lib/s3'

# Invoice model needs a live Sequel connection at class-definition time.
if ENV['DATABASE_URL']
  DB.connect!
  DB.migrate!
  require_relative 'lib/invoice'
  require_relative 'lib/invoice_pdf'
else
  $logger.warn('DATABASE_URL not set — invoicing disabled')
end

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
  use AdminAuth

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

  # --- Admin: invoices ----------------------------------------------------

  before '/admin/*' do
    halt 503, 'Invoicing not configured (DATABASE_URL missing).' unless defined?(Invoice)
  end

  before '/i/*' do
    halt 503, 'Invoicing not configured (DATABASE_URL missing).' unless defined?(Invoice)
  end

  get '/admin' do
    redirect '/admin/invoices'
  end

  get '/admin/invoices' do
    @page_title = 'Invoices — admin'
    @noindex    = true
    @invoices   = Invoice.order(Sequel.desc(:created_at)).all
    erb :'admin/invoices/index'
  end

  get '/admin/invoices/new' do
    @page_title  = 'New invoice — admin'
    @noindex     = true
    @form_errors = nil
    @form_values = {}
    erb :'admin/invoices/new'
  end

  post '/admin/invoices' do
    @form_values = {
      client_name:    params[:client_name].to_s.strip,
      client_email:   params[:client_email].to_s.strip,
      client_address: params[:client_address].to_s.strip,
      currency:       params[:currency].to_s.upcase,
      gel_rate:       params[:gel_rate].to_s.strip,
      issued_on:      params[:issued_on].to_s.strip,
      due_on:         params[:due_on].to_s.strip,
      notes:          params[:notes].to_s.strip,
      items:          (params[:items] || {}).values
    }
    @form_errors = validate_invoice_params(@form_values)

    if @form_errors.any?
      @page_title = 'New invoice — admin'
      @noindex    = true
      status 422
      return erb :'admin/invoices/new'
    end

    invoice = Invoice.build(@form_values)
    pdf_bytes = InvoicePdf.render(invoice)
    pdf_key   = "invoices/#{invoice.number}-#{invoice.uuid}.pdf"
    S3.put(pdf_key, pdf_bytes)
    invoice.pdf_key = pdf_key
    invoice.save_changes

    redirect "/admin/invoices/#{invoice.uuid}"
  end

  get '/admin/invoices/:uuid' do
    @invoice = Invoice[uuid: params[:uuid]] or halt 404
    @page_title = "#{@invoice.number} — admin"
    @noindex    = true
    erb :'admin/invoices/show'
  end

  post '/admin/invoices/:uuid/paid' do
    invoice = Invoice[uuid: params[:uuid]] or halt 404
    invoice.paid_at = invoice.paid? ? nil : Time.now.utc
    invoice.save_changes
    redirect "/admin/invoices/#{invoice.uuid}"
  end

  # --- Public: invoice landing + PDF download -----------------------------

  get '/i/:uuid' do
    @invoice = Invoice[uuid: params[:uuid]] or halt 404
    @page_title = "Invoice #{@invoice.number}"
    @page_desc  = "Invoice #{@invoice.number} from IE Sergei Poljanski."
    @noindex    = true
    erb :invoice_public
  end

  get '/i/:uuid/pdf' do
    invoice = Invoice[uuid: params[:uuid]] or halt 404
    url = S3.presigned_url(invoice.pdf_key,
                           expires_in: 300,
                           filename:   "#{invoice.number}.pdf")
    redirect url, 302
  end

  not_found do
    status 404
    'Not found'
  end

  error 403 do
    'Forbidden — likely CSRF token expired. Reload the page and try again.'
  end

  helpers do
    def validate_invoice_params(v)
      errors = {}
      errors[:client_name]  = 'Client name required (1–200 chars)' if v[:client_name].empty? || v[:client_name].length > 200
      errors[:client_email] = 'Valid client email required'        if v[:client_email].empty? || v[:client_email] !~ URI::MailTo::EMAIL_REGEXP
      errors[:currency]     = 'Unsupported currency'               unless Invoice::CURRENCIES.include?(v[:currency])
      begin
        raise ArgumentError if v[:gel_rate].empty?
        BigDecimal(v[:gel_rate])
      rescue ArgumentError
        errors[:gel_rate] = 'GEL rate must be a positive decimal'
      end
      items = v[:items].select { |i| i.is_a?(Hash) && !i['description'].to_s.strip.empty? }
      errors[:items] = 'At least one line item with a description is required' if items.empty?
      v[:items] = items
      errors
    end
  end
end
