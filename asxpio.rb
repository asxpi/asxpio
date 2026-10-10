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

require_relative 'lib/fmt'
require_relative 'lib/mailer'
require_relative 'lib/rate_limit'
require_relative 'lib/db'
require_relative 'lib/admin_auth'
require_relative 'lib/s3'
require_relative 'lib/bingo_admin'
require_relative 'lib/users_admin'

# Invoice model needs a live Sequel connection at class-definition time.
if ENV['DATABASE_URL']
  DB.connect!
  DB.migrate!
  require_relative 'lib/invoice'
  require_relative 'lib/crypto_asset'
  require_relative 'lib/crypto_rate'
  require_relative 'lib/crypto_qr'
  require_relative 'lib/gel_rate'
  require_relative 'lib/invoice_pdf'
  require_relative 'lib/bingo'
  Bingo.seed!
  require_relative 'lib/user'
  require_relative 'lib/audit'
  require_relative 'lib/payout_address'
  PayoutAddress.seed_from_env!
  User.bootstrap!(ENV['ADMIN_USER'], ENV['ADMIN_PASSWORD'])
else
  $logger.warn('DATABASE_URL not set — invoicing disabled')
end

class AsxpioWeb < Sinatra::Base
  RATE_LIMIT = RateLimit.new(limit: 5, window: 3600)

  configure do
    set :root, $root
    set :erb, layout: :layout, escape_html: true
    set :show_exceptions, $env == 'development'
    # Traefik only routes our hostnames anyway; this is defense in depth.
    # 127.0.0.1 is the Docker HEALTHCHECK. Empty list (= check disabled)
    # outside production so dev and rack-test hosts keep working.
    set :host_authorization,
        { permitted_hosts: $env == 'production' ? ['asxp.io', 'www.asxp.io', '127.0.0.1'] : [] }
  end

  use Rack::Session::Cookie,
      key:          'asxpio.session',
      path:         '/',
      secret:       ENV.fetch('SESSION_SECRET'),
      expire_after: 3600,
      same_site:    :lax

  use Rack::Protection::AuthenticityToken
  register AdminAuth
  register BingoAdmin
  register UsersAdmin

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

    def fmt_rate(value, min_dp = 4)
      Fmt.rate(value, min_dp: min_dp)
    end

    def fmt_crypto(value)
      Fmt.crypto(value)
    end

    # Hidden invoices exist only for superusers in the admin.
    def visible_invoices
      current_user&.superuser ? Invoice.dataset : Invoice.where(hidden: false)
    end

    def admin_invoice!(uuid)
      visible_invoices.first(uuid: uuid) or halt 404
    end
  end

  before do
    cache_control :private, :must_revalidate, max_age: 0
  end

  get '/' do
    erb :index
  end

  get '/keys' do
    @page_title = 'Keys · Sergei Poljanski'
    @page_desc  = 'PGP fingerprint and SSH public key of Sergei Poljanski. Verify or download the key files.'
    erb :keys
  end

  get '/contact' do
    @page_title = 'Contact · Sergei Poljanski'
    @page_desc  = 'Contact Sergei Poljanski: email, Telegram, phone. Legal entity details for invoices and contracts.'
    erb :contact
  end

  # Liveness for the Docker HEALTHCHECK and the deploy pipeline. Pings the DB
  # when invoicing is configured — a wedged connection pool should read as
  # unhealthy, not just "process exists".
  get '/healthz' do
    begin
      DB.connection['SELECT 1'].get if defined?(Invoice)
    rescue Sequel::Error
      halt 503, 'db unreachable'
    end
    'ok'
  end

  # --- Admin: invoices ----------------------------------------------------

  before '/admin/*' do
    halt 503, 'Invoicing not configured (DATABASE_URL missing).' unless defined?(Invoice)
  end

  before '/i/*' do
    halt 503, 'Invoicing not configured (DATABASE_URL missing).' unless defined?(Invoice)
  end

  # Overview of every admin area; each tile links into its section.
  get '/admin' do
    @page_title = 'Dashboard · admin'
    @noindex    = true
    if can?('invoices', 'read')
      unpaid = visible_invoices.where(paid_at: nil, cancelled_at: nil).all
      @inv = {
        count:         visible_invoices.count,
        unpaid:        unpaid,
        overdue:       unpaid.count { |i| i.due_on < Date.today },
        unpaid_totals: unpaid.group_by(&:currency).transform_values { |l| l.sum(&:total) },
        recent:        visible_invoices.order(Sequel.desc(:created_at)).limit(5).all
      }
    end
    if can?('bingo', 'read')
      board = Bingo::Board.load
      @bingo = {
        cells:         board.cells.size,
        hit:           board.hit.count(true),
        lines:         board.wins.size,
        reserve:       [Bingo::Datacenter.count - board.cells.size, 0].max,
        last_incident: board.incidents.first,
        no_photo:      board.cells.reject(&:photo_key)
      }
    end
    erb :'admin/dashboard'
  end

  get '/admin/invoices' do
    @page_title = 'Invoices · admin'
    @noindex    = true
    @invoices   = visible_invoices.order(Sequel.desc(:created_at)).all
    erb :'admin/invoices/index'
  end

  # Live price of the selected crypto asset for the new-invoice form's
  # "Fetch live" button. GEL is derived from the gel_rate the operator typed
  # into the form.
  get '/admin/crypto-rate' do
    content_type :json
    coin     = params[:coin].to_s.upcase
    currency = params[:currency].to_s.upcase
    gel_rate = params[:gel_rate].to_s.strip
    begin
      rate = CryptoRate.fetch(coin, currency, gel_rate: gel_rate.empty? ? nil : gel_rate)
      { rate: rate.round(8).to_s('F'), coin: coin, currency: currency }.to_json
    rescue CryptoRate::Error => e
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

  # Defined before /admin/invoices/:uuid, which would otherwise match it.
  get '/admin/invoices/payout-addresses' do
    @page_title = 'Payout addresses · admin'
    @noindex    = true
    @addresses  = PayoutAddress.as_hash(:coin)
    @flash      = session.delete(:payout_flash)
    erb :'admin/invoices/payout_addresses'
  end

  post '/admin/invoices/payout-addresses' do
    before = PayoutAddress.map
    errors = CryptoAsset::CODES.filter_map do |coin|
      next unless params.dig('address', coin)
      PayoutAddress.set!(coin, params['address'][coin], by: current_user.username)
    end
    changed = (before.keys | PayoutAddress.map.keys).reject { |c| before[c] == PayoutAddress.map[c] }
    audit!('invoice.payout_addresses', changed.join(', '), nil) if changed.any?
    session[:payout_flash] = errors.any? ? errors.join('; ') : "Saved#{" (#{changed.join(', ')})" if changed.any?}."
    redirect '/admin/invoices/payout-addresses'
  end

  get '/admin/invoices/new' do
    @page_title  = 'New invoice · admin'
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
    src = admin_invoice!(params[:uuid])
    term = (src.due_on - src.issued_on).to_i
    @page_title  = 'New invoice · admin'
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
      crypto_coin:    src.crypto_coin,
      crypto_address: src.crypto_address,
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
      crypto_coin:    params[:crypto_coin].to_s.upcase,
      crypto_address: params[:crypto_address].to_s.strip,
      crypto_rate:    params[:crypto_rate].to_s.strip,
      crypto_amount:  params[:crypto_amount].to_s.strip,
      items:          (params[:items] || {}).values
    }
    @form_errors = validate_invoice_params(@form_values)

    if @form_errors.any?
      @page_title = 'New invoice · admin'
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

    audit!('invoice.create', invoice.number, "#{invoice.client_name}, #{invoice.currency} #{'%.2f' % invoice.total}")
    redirect "/admin/invoices/#{invoice.uuid}"
  end

  get '/admin/invoices/:uuid' do
    @invoice = admin_invoice!(params[:uuid])
    @page_title = "#{@invoice.number} · admin"
    @noindex    = true
    erb :'admin/invoices/show'
  end

  post '/admin/invoices/:uuid/paid' do
    invoice = admin_invoice!(params[:uuid])
    halt 422, 'Cancelled invoices cannot be marked paid; reinstate it first.' if invoice.cancelled?
    invoice.paid_at = invoice.paid? ? nil : Time.now.utc
    invoice.save_changes
    audit!(invoice.paid? ? 'invoice.paid' : 'invoice.unpaid', invoice.number)
    redirect "/admin/invoices/#{invoice.uuid}"
  end

  # Cancel: a third PDF variant with a CANCELLED stamp becomes current, so
  # the client's link and download switch over. Reinstate undoes it.
  post '/admin/invoices/:uuid/cancel' do
    invoice = admin_invoice!(params[:uuid])
    halt 422, 'Already cancelled.' if invoice.cancelled?
    invoice.cancelled_at  = Time.now.utc
    invoice.cancel_reason = params[:reason].to_s.strip[0, 500].then { |r| r.empty? ? nil : r }
    S3.put(invoice.pdf_key_for('cancelled'), InvoicePdf.render(invoice, status: 'cancelled'))
    invoice.save_changes
    audit!('invoice.cancel', invoice.number, invoice.cancel_reason)
    redirect "/admin/invoices/#{invoice.uuid}"
  end

  post '/admin/invoices/:uuid/reinstate' do
    invoice = admin_invoice!(params[:uuid])
    invoice.update(cancelled_at: nil, cancel_reason: nil)
    audit!('invoice.reinstate', invoice.number)
    redirect "/admin/invoices/#{invoice.uuid}"
  end

  # Superuser-only: hidden invoices vanish from the admin for everyone else
  # (the client's public link keeps working).
  post '/admin/invoices/:uuid/hide' do
    halt 403, 'Only superusers can hide invoices.' unless current_user.superuser
    invoice = admin_invoice!(params[:uuid])
    invoice.update(hidden: !invoice.hidden)
    audit!(invoice.hidden ? 'invoice.hide' : 'invoice.unhide', invoice.number)
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

      # Crypto is optional; validate only when an address is present.
      unless v[:crypto_address].to_s.strip.empty?
        errors[:crypto_coin] = 'Unknown coin' unless CryptoAsset.valid?(v[:crypto_coin])
        # Loose shape check: every supported chain's addresses are alphanumeric.
        errors[:crypto_address] = 'Address looks invalid' unless v[:crypto_address] =~ /\A[a-zA-Z0-9]{10,128}\z/
        %i[crypto_rate crypto_amount].each do |k|
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
