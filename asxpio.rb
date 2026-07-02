require 'logger'
require 'bigdecimal'
require 'sinatra/base'
require 'sinatra/contrib'
require 'erubi'
require 'uri'

begin
  require 'dotenv'
  # Tests control ENV themselves; a developer's .env must not leak in (it may
  # point DATABASE_URL at a real database).
  Dotenv.load unless ENV['RACK_ENV'] == 'test'
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
  require_relative 'lib/ltc_rate'
  require_relative 'lib/ltc_qr'
  require_relative 'lib/gel_rate'
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

    # Exchange rate for display: full captured precision (up to 8 dp), trailing
    # zeros trimmed, padded to at least min_dp. Mirrors InvoicePdf#fmt_rate so
    # the HTML and PDF agree. (4 dp matches the NBG's GEL quoting.)
    def fmt_rate(value, min_dp = 4)
      frac = BigDecimal(value.to_s).round(8).to_s('F').split('.').last.sub(/0+$/, '')
      whole = BigDecimal(value.to_s).to_i
      "#{whole}.#{frac.ljust(min_dp, '0')}"
    end

    # LTC amount: up to 8 dp, trailing zeros trimmed, no padding.
    def fmt_ltc(value)
      BigDecimal(value.to_s).round(8).to_s('F').sub(/(\.\d*?)0+$/, '\1').sub(/\.$/, '')
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

  # Live LTC price for the new-invoice form's "Fetch live" button.
  # GEL is derived from the gel_rate the operator typed into the form.
  get '/admin/ltc-rate' do
    content_type :json
    currency = params[:currency].to_s.upcase
    gel_rate = params[:gel_rate].to_s.strip
    begin
      rate = LtcRate.fetch(currency, gel_rate: gel_rate.empty? ? nil : gel_rate)
      { rate: rate.round(8).to_s('F'), currency: currency }.to_json
    rescue LtcRate::Error => e
      status 502
      { error: e.message }.to_json
    end
  end

  # Official GEL rate from the National Bank of Georgia for the new-invoice
  # form's "Fetch official" button. The rate is GEL per 1 unit of the invoice
  # currency (USD/EUR), so it tracks the form's selected currency. Pass date=
  # for a past invoice (NBG rolls back to the last published rate on
  # weekends/holidays). GEL invoices have a trivial rate of 1 — no fetch needed.
  get '/admin/gel-rate' do
    content_type :json
    currency = params[:currency].to_s.upcase
    currency = 'USD' if currency.empty?
    date = params[:date].to_s.strip

    if currency == 'GEL'
      return { rate: '1', currency: 'GEL', date: date }.to_json
    end

    begin
      rate = GelRate.fetch(currency, date: date.empty? ? nil : date)
      { rate: rate.to_s('F').sub(/(\.\d*?)0+$/, '\1').sub(/\.$/, ''), currency: currency, date: date }.to_json
    rescue GelRate::Error => e
      status 502
      { error: e.message }.to_json
    end
  end

  get '/admin/invoices/new' do
    @page_title  = 'New invoice — admin'
    @noindex     = true
    @form_errors = nil
    @form_values = {}
    erb :'admin/invoices/new'
  end

  # Start a new invoice prefilled from an existing one ("use as template").
  # Reuses the new-invoice form via @form_values. Issue date resets to today and
  # the due date keeps the source's payment term (same issued→due gap, anchored
  # to today). The snapshotted LTC rate/amount are dropped (stale prices) — the
  # address is kept so the operator only re-fetches the live rate.
  get '/admin/invoices/:uuid/duplicate' do
    src = Invoice[uuid: params[:uuid]] or halt 404
    term = (src.due_on - src.issued_on).to_i
    @page_title  = 'New invoice — admin'
    @noindex     = true
    @form_errors = nil
    @form_values = {
      client_name:    src.client_name,
      client_email:   src.client_email,
      client_address: src.client_address,
      currency:       src.currency,
      gel_rate:       src.gel_rate.to_s,
      issued_on:      Date.today.strftime('%Y-%m-%d'),
      due_on:         (Date.today + term).strftime('%Y-%m-%d'),
      notes:          src.notes,
      ltc_address:    src.ltc_address,
      items:          src.items_array
    }
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
      ltc_address:    params[:ltc_address].to_s.strip,
      ltc_rate:       params[:ltc_rate].to_s.strip,
      ltc_amount:     params[:ltc_amount].to_s.strip,
      items:          (params[:items] || {}).values
    }
    @form_errors = validate_invoice_params(@form_values)

    if @form_errors.any?
      @page_title = 'New invoice — admin'
      @noindex    = true
      status 422
      return erb :'admin/invoices/new'
    end

    # The whole build→render→upload→save sequence retries on a duplicate
    # number: two concurrent creates (Puma threads) can both compute MAX+1.
    # The PDF embeds the number, so a retry must re-render, not just re-save.
    # A losing attempt orphans its two S3 objects; harmless and near-impossible
    # with a single operator.
    attempts = 0
    begin
      invoice = Invoice.build(@form_values)
      # Base key (no suffix); the two status variants get -pending/-paid appended.
      invoice.pdf_key = "invoices/#{invoice.number}-#{invoice.uuid}.pdf"
      %w[pending paid].each do |st|
        S3.put(invoice.pdf_key_for(st), InvoicePdf.render(invoice, status: st))
      end
      invoice.save_changes
    rescue Sequel::UniqueConstraintViolation
      attempts += 1
      raise if attempts > 2
      retry
    end

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
    # Prefer the status variant; fall back to the legacy single-PDF key for
    # invoices created before the pending/paid split.
    key = invoice.current_pdf_key
    key = invoice.pdf_key unless S3.exists?(key)
    url = S3.presigned_url(key,
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
        raise ArgumentError if v[:gel_rate].empty? || BigDecimal(v[:gel_rate]) <= 0
      rescue ArgumentError
        errors[:gel_rate] = 'GEL rate must be a positive decimal'
      end
      items = v[:items].select { |i| i.is_a?(Hash) && !i['description'].to_s.strip.empty? }
      errors[:items] = 'At least one line item with a description is required' if items.empty?
      # Blank qty/price default to 0 in Invoice.normalize_items; non-blank must
      # parse, or BigDecimal would raise a 500 out of Invoice.build.
      items.each do |i|
        %w[qty unit_price].each do |k|
          raw = i[k].to_s
          next if raw.empty?
          begin
            BigDecimal(raw)
          rescue ArgumentError
            errors[:items] = 'Qty and unit price must be decimal numbers (use a dot, e.g. 1.5)'
          end
        end
      end
      v[:items] = items

      # LTC is optional; validate only when an address is present.
      unless v[:ltc_address].to_s.strip.empty?
        errors[:ltc_address] = 'LTC address looks invalid' unless v[:ltc_address] =~ /\A(ltc1|[LM3])[a-zA-HJ-NP-Z0-9]{20,90}\z/
        %i[ltc_rate ltc_amount].each do |k|
          next if v[k].to_s.strip.empty?
          begin
            raise ArgumentError if BigDecimal(v[k]) <= 0
          rescue ArgumentError
            errors[k] = "#{k.to_s.tr('_', ' ').capitalize} must be a positive decimal"
          end
        end
      end
      errors
    end
  end
end
