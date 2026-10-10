require_relative 'test_helper'

class InvoiceCancelTest < Minitest::Test
  include Rack::Test::Methods
  include AdminLogin

  def app
    AsxpioWeb
  end

  def setup
    skip 'TEST_DATABASE_URL not set' unless TestDb.available?
    TestDb.clean!
    TestDb.clean_users!
    @inv = Invoice.build(client_name: 'ACME', client_email: 'b@example.com', currency: 'EUR', gel_rate: '3.05',
                         items: [{ 'description' => 'work', 'qty' => '1', 'unit_price' => '100' }])
    @inv.pdf_key = "invoices/#{@inv.number}-#{@inv.uuid}.pdf"
    @inv.save_changes
  end

  def token
    get '/admin'
    last_response.body[/name="authenticity_token" value="([^"]+)"/, 1]
  end

  def test_cancel_marks_status_and_renders_cancelled_pdf
    admin_login!
    post "/admin/invoices/#{@inv.uuid}/cancel", { authenticity_token: token, reason: 'Duplicate of INV-1' }
    assert_equal 302, last_response.status
    @inv.refresh
    assert @inv.cancelled?
    assert_equal 'cancelled', @inv.status
    assert_equal 'Duplicate of INV-1', @inv.cancel_reason
    assert_match(/-cancelled\.pdf\z/, @inv.current_pdf_key)
    get "/i/#{@inv.uuid}"
    assert_includes last_response.body, 'badge-cancelled'
    assert_includes last_response.body, 'not payable'

    post "/admin/invoices/#{@inv.uuid}/paid", { authenticity_token: token }
    assert_equal 422, last_response.status

    post "/admin/invoices/#{@inv.uuid}/reinstate", { authenticity_token: token }
    refute @inv.refresh.cancelled?
    assert_equal 'pending', @inv.status
  end

  # Every state of the admin invoice page renders (pending, paid,
  # cancelled, hidden), for a superuser and for a read-only user.
  def test_admin_invoice_page_renders_in_every_state
    admin_login!
    get "/admin/invoices/#{@inv.uuid}"
    assert last_response.ok?, last_response.body[0, 300]
    assert_includes last_response.body, 'Cancel invoice'
    @inv.update(paid_at: Time.now.utc)
    get "/admin/invoices/#{@inv.uuid}"
    assert last_response.ok?, last_response.body[0, 300]
    @inv.update(cancelled_at: Time.now.utc, cancel_reason: 'dup', hidden: true)
    get "/admin/invoices/#{@inv.uuid}"
    assert last_response.ok?, last_response.body[0, 300]
    assert_includes last_response.body, 'Reinstate'
  end

  def test_cancelled_pdf_renders
    @inv.cancelled_at = Time.now.utc
    @inv.cancel_reason = 'wrong client'
    pdf = InvoicePdf.render(@inv, status: 'cancelled')
    assert pdf.start_with?('%PDF')
  end

  def test_hidden_invoice_only_for_superusers
    admin_login!
    post "/admin/invoices/#{@inv.uuid}/hide", { authenticity_token: token }
    assert @inv.refresh.hidden
    get '/admin/invoices'
    assert_includes last_response.body, 'badge-hidden'

    clear_cookies
    @admin_logged_in = false
    u = User.create(username: 'clerk', password: 'clerk-password-1')
    UserPermission.create(user_id: u.id, area: 'invoices', can_read: true, can_write: true)
    admin_login!(username: 'clerk', password: 'clerk-password-1')
    get '/admin/invoices'
    refute_includes last_response.body, @inv.number
    get "/admin/invoices/#{@inv.uuid}"
    assert_equal 404, last_response.status
    post "/admin/invoices/#{@inv.uuid}/hide", { authenticity_token: token }
    assert_equal 403, last_response.status
    get '/admin'
    refute_includes last_response.body, @inv.number
    get "/i/#{@inv.uuid}"
    assert last_response.ok?                      # client link unaffected
  end

  def test_dashboard_ignores_cancelled_for_outstanding
    @inv.update(cancelled_at: Time.now.utc)
    admin_login!
    get '/admin'
    assert_match %r{<b>0</b><span>unpaid</span>}, last_response.body
  end
end
