require_relative 'test_helper'

class InvoiceStatsTest < Minitest::Test
  include Rack::Test::Methods
  include AdminLogin

  def app
    AsxpioWeb
  end

  def setup
    skip 'TEST_DATABASE_URL not set' unless TestDb.available?
    TestDb.clean!
    TestDb.clean_users!
  end

  def make(client:, price:, issued:, paid: nil, cancelled: false, currency: 'EUR', rate: '3')
    i = Invoice.build(client_name: client, client_email: 'c@example.com', currency: currency, gel_rate: rate,
                      issued_on: issued.to_s, due_on: (issued + 14).to_s,
                      items: [{ 'description' => 'work', 'qty' => '1', 'unit_price' => price.to_s }])
    i.pdf_key = "invoices/#{i.number}-#{i.uuid}.pdf"
    i.paid_at = Time.utc(paid.year, paid.month, paid.day, 12) if paid
    i.cancelled_at = Time.now.utc if cancelled
    i.save_changes
    i
  end

  def test_figures
    make(client: 'ACME', price: 100, issued: Date.new(2026, 1, 10), paid: Date.new(2026, 2, 5))   # 300 GEL, 26 days
    make(client: 'ACME', price: 50,  issued: Date.new(2026, 2, 1))                                # 150 GEL, unpaid
    make(client: 'Beta', price: 200, issued: Date.new(2026, 2, 3), cancelled: true)               # ignored
    make(client: 'Old',  price: 10,  issued: Date.new(2025, 12, 1), paid: Date.new(2026, 1, 2), currency: 'USD', rate: '2.7')

    s = InvoiceStats.new(Invoice.all, year: 2026)
    assert_equal 2, s.live.size
    assert_equal 1, s.cancelled.size
    assert_equal BigDecimal('450'), s.gel(s.live)
    assert_equal BigDecimal('150'), s.gel(s.unpaid)
    assert_equal 26, s.avg_days_to_pay
    jan = s.monthly[0]
    feb = s.monthly[1]
    assert_equal [1, BigDecimal('300')], [jan[1], jan[2]]
    assert_equal BigDecimal('27'), jan[3]          # 2025 invoice paid in Jan 2026 counts as received then
    assert_equal BigDecimal('300'), feb[3]         # paid by payment date
    assert_equal 12, s.monthly.size
    assert_equal [['ACME', 2, BigDecimal('450')]], s.top_clients
    assert_equal [2026, 2025], s.years

    all = InvoiceStats.new(Invoice.all)
    assert_equal 3, all.live.size
    assert_equal({ 'EUR' => { invoiced: BigDecimal('150'), paid: BigDecimal('100'), outstanding: BigDecimal('50') },
                   'USD' => { invoiced: BigDecimal('10'), paid: BigDecimal('10'), outstanding: BigDecimal('0') } }, all.by_currency)
  end

  def test_page_renders_and_respects_hidden
    make(client: 'ACME', price: 100, issued: Date.today - 20, paid: Date.today - 5)
    h = make(client: 'Secret Ltd', price: 999, issued: Date.today - 3)
    h.update(hidden: true)
    admin_login!
    get '/admin/invoices/stats'
    assert last_response.ok?, last_response.body[0, 300]
    assert_includes last_response.body, 'Secret Ltd'                 # superuser sees hidden
    assert_includes last_response.body, 'class="bar-chart"'
    get "/admin/invoices/stats?year=#{Date.today.year}"
    assert last_response.ok?

    clear_cookies
    @admin_logged_in = false
    u = User.create(username: 'clerk', password: 'clerk-password-1')
    UserPermission.create(user_id: u.id, area: 'invoices', can_read: true)
    admin_login!(username: 'clerk', password: 'clerk-password-1')
    get '/admin/invoices/stats'
    assert last_response.ok?
    refute_includes last_response.body, 'Secret Ltd'
  end

  def test_empty_state
    admin_login!
    get '/admin/invoices/stats'
    assert last_response.ok?
  end
end
