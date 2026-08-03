require_relative 'test_helper'

class AppTest < Minitest::Test
  include Rack::Test::Methods

  def app
    AsxpioWeb
  end

  def setup
    Mail::TestMailer.deliveries.clear
    TestDb.clean! if TestDb.available?
  end

  def csrf_token_from(path, env = {})
    get path, {}, env
    assert last_response.ok?, "GET #{path} failed: #{last_response.status}"
    last_response.body[/name="authenticity_token" value="([^"]+)"/, 1] ||
      flunk("no CSRF token found on #{path}")
  end

  def admin_env(extra = {})
    { 'HTTP_AUTHORIZATION' =>
        "Basic #{Base64.strict_encode64("#{ENV['ADMIN_USER']}:#{ENV['ADMIN_PASSWORD']}")}" }.merge(extra)
  end

  # --- public pages ---------------------------------------------------------

  def test_index_renders
    get '/'
    assert last_response.ok?
  end

  def test_healthz
    get '/healthz'
    assert last_response.ok?
    assert_equal 'ok', last_response.body
  end

  # --- contact page ---------------------------------------------------------
  # The form was removed (persistent spam); the page keeps the direct contacts.

  def test_contact_page_renders_without_form
    get '/contact'
    assert last_response.ok?
    assert_includes last_response.body, 'ie@asxp.io'
    refute_match %r{<form[^>]*action="/contact"}, last_response.body
  end

  def test_contact_post_is_gone
    post '/contact', { name: 'Spam', message: 'Spam' }
    refute_equal 302, last_response.status
    assert_empty Mail::TestMailer.deliveries
  end

  # --- admin ------------------------------------------------------------

  def test_admin_requires_auth
    get '/admin/invoices'
    assert_equal 401, last_response.status
  end

  def test_admin_list_with_auth
    skip 'TEST_DATABASE_URL not set' unless TestDb.available?
    get '/admin/invoices', {}, admin_env
    assert last_response.ok?
  end

  def invoice_form_params(token)
    { authenticity_token: token,
      client_name: 'ACME', client_email: 'billing@example.com', client_address: '',
      currency: 'EUR', gel_rate: '3.05',
      issued_on: Date.today.to_s, due_on: (Date.today + 14).to_s, notes: '',
      crypto_coin: 'LTC', crypto_address: '', crypto_rate: '', crypto_amount: '',
      items: { '0' => { 'description' => 'Engineering — test', 'qty' => '2', 'unit_price' => '100.50' } } }
  end

  def test_create_invoice_end_to_end
    skip 'TEST_DATABASE_URL not set' unless TestDb.available?
    token = csrf_token_from('/admin/invoices/new', admin_env)

    post '/admin/invoices', invoice_form_params(token), admin_env
    assert_equal 302, last_response.status, last_response.body

    invoice = Invoice.first
    refute_nil invoice
    assert_equal BigDecimal('201'), invoice.total
    assert_equal "invoices/#{invoice.number}-#{invoice.uuid}.pdf", invoice.pdf_key
    assert_match %r{/admin/invoices/#{invoice.uuid}}, last_response.location
  end

  def test_create_invoice_with_crypto
    skip 'TEST_DATABASE_URL not set' unless TestDb.available?
    token = csrf_token_from('/admin/invoices/new', admin_env)

    params = invoice_form_params(token).merge(
      crypto_coin: 'USDT-TRC20', crypto_address: 'TXYZexampleexampleexampleexample12',
      crypto_rate: '1.00', crypto_amount: ''
    )
    post '/admin/invoices', params, admin_env
    assert_equal 302, last_response.status, last_response.body

    invoice = Invoice.first
    assert_equal 'USDT-TRC20', invoice.crypto_coin
    assert_equal BigDecimal('201'), invoice.crypto_amount_due
  end

  def test_create_invoice_validation_failure_rerenders_form
    skip 'TEST_DATABASE_URL not set' unless TestDb.available?
    token = csrf_token_from('/admin/invoices/new', admin_env)

    params = invoice_form_params(token)
    params[:items]['0']['qty'] = '1,5'
    post '/admin/invoices', params, admin_env
    assert_equal 422, last_response.status
    assert_nil Invoice.first
  end

  # --- public invoice pages -----------------------------------------------

  def create_invoice!
    inv = Invoice.build(
      client_name: 'ACME', client_email: 'billing@example.com',
      currency: 'EUR', gel_rate: '3.05',
      items: [{ 'description' => 'work', 'qty' => '1', 'unit_price' => '100' }]
    )
    inv.pdf_key = "invoices/#{inv.number}-#{inv.uuid}.pdf"
    inv.save_changes
    inv
  end

  def test_public_landing_page
    skip 'TEST_DATABASE_URL not set' unless TestDb.available?
    inv = create_invoice!
    get "/i/#{inv.uuid}"
    assert last_response.ok?
    assert_includes last_response.body, inv.number
    assert_includes last_response.body, 'ACME'
  end

  def test_public_pdf_redirects_to_presigned_url
    skip 'TEST_DATABASE_URL not set' unless TestDb.available?
    inv = create_invoice!
    get "/i/#{inv.uuid}/pdf"
    assert_equal 302, last_response.status
    assert_includes last_response.location, 'X-Amz-Signature'
  end

  def test_unknown_invoice_404s
    skip 'TEST_DATABASE_URL not set' unless TestDb.available?
    get "/i/#{SecureRandom.uuid}"
    assert_equal 404, last_response.status
  end
end
