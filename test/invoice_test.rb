require_relative 'test_helper'

class InvoiceTest < Minitest::Test
  def setup
    skip 'TEST_DATABASE_URL not set' unless TestDb.available?
    TestDb.clean!
    @year = Date.today.year
  end

  def insert_number(num)
    DB.connection[:invoices].insert(
      uuid: SecureRandom.uuid, number: num, client_name: 'c', client_email: 'c@example.com',
      currency: 'EUR', gel_rate: 3, subtotal: 1,
      items: [{ 'description' => 'x', 'qty' => '1', 'unit_price' => '1' }].to_json,
      issued_on: Date.today, due_on: Date.today + 14, pdf_key: 'k', created_at: Time.now.utc
    )
  end

  def test_allocate_number_starts_at_one
    assert_equal "INV-#{@year}-0001", Invoice.allocate_number
  end

  def test_allocate_number_increments
    insert_number("INV-#{@year}-0001")
    insert_number("INV-#{@year}-0002")
    assert_equal "INV-#{@year}-0003", Invoice.allocate_number
  end

  def test_allocate_number_sorts_numerically_past_9999
    insert_number("INV-#{@year}-9999")
    insert_number("INV-#{@year}-10000")
    assert_equal "INV-#{@year}-10001", Invoice.allocate_number
  end

  def test_allocate_number_ignores_other_years
    insert_number("INV-#{@year - 1}-0500")
    assert_equal "INV-#{@year}-0001", Invoice.allocate_number
  end

  def test_duplicate_number_raises_unique_violation
    insert_number("INV-#{@year}-0001")
    assert_raises(Sequel::UniqueConstraintViolation) { insert_number("INV-#{@year}-0001") }
  end

  def test_build_round_trip
    inv = Invoice.build(
      client_name: 'ACME', client_email: 'billing@example.com', client_address: '',
      currency: 'EUR', gel_rate: '3.05', issued_on: '', due_on: '', notes: '',
      items: [{ 'description' => 'work', 'qty' => '2', 'unit_price' => '100.50' }]
    )
    inv.pdf_key = "invoices/#{inv.number}-#{inv.uuid}.pdf"
    inv.save_changes

    saved = Invoice[uuid: inv.uuid]
    assert_equal BigDecimal('201'), saved.total
    assert_equal BigDecimal('613.05'), saved.total_gel
    assert_equal 'pending', saved.status
    refute saved.crypto?
  end

  def test_build_derives_crypto_amount_from_rate
    inv = Invoice.build(
      client_name: 'ACME', client_email: 'billing@example.com',
      currency: 'EUR', gel_rate: '3.05',
      items: [{ 'description' => 'work', 'qty' => '1', 'unit_price' => '100' }],
      crypto_coin: 'ltc', crypto_address: 'ltc1qexampleexampleexampleexample',
      crypto_rate: '80', crypto_amount: ''
    )
    assert inv.crypto?
    assert_equal 'LTC', inv.crypto_coin
    assert_equal BigDecimal('1.25'), inv.crypto_amount_due
  end

  def test_build_rejects_unknown_coin
    assert_raises(ArgumentError) do
      Invoice.build(
        client_name: 'ACME', client_email: 'billing@example.com',
        currency: 'EUR', gel_rate: '3.05',
        items: [{ 'description' => 'work', 'qty' => '1', 'unit_price' => '100' }],
        crypto_coin: 'DOGE', crypto_address: 'D6examplexampleexampleexample'
      )
    end
  end
end

class InvoiceValidationTest < Minitest::Test
  BASE = {
    client_name: 'ACME', client_email: 'billing@example.com', currency: 'EUR',
    gel_rate: '3.05', crypto_coin: 'LTC', crypto_address: '', crypto_rate: '', crypto_amount: '',
    items: [{ 'description' => 'work', 'qty' => '1', 'unit_price' => '100' }]
  }.freeze

  def setup
    skip 'TEST_DATABASE_URL not set' unless TestDb.available?
    @app = AsxpioWeb.new!
  end

  def validate(over = {})
    @app.send(:validate_invoice_params, BASE.merge(over).dup)
  end

  def test_valid_params_pass
    assert_empty validate
  end

  def test_gel_rate_must_be_positive
    assert_includes validate(gel_rate: '0'), :gel_rate
    assert_includes validate(gel_rate: '-2.9'), :gel_rate
    refute_includes validate(gel_rate: '2.95'), :gel_rate
  end

  def test_item_numbers_must_parse
    assert_includes validate(items: [{ 'description' => 'w', 'qty' => '1,5', 'unit_price' => '100' }]), :items
    assert_includes validate(items: [{ 'description' => 'w', 'qty' => '1', 'unit_price' => 'abc' }]), :items
  end

  def test_blank_item_numbers_allowed
    assert_empty validate(items: [{ 'description' => 'w', 'qty' => '', 'unit_price' => '' }])
  end

  def test_at_least_one_item_required
    assert_includes validate(items: [{ 'description' => '', 'qty' => '1', 'unit_price' => '1' }]), :items
  end

  def test_crypto_address_format
    assert_includes validate(crypto_address: 'not!an@address'), :crypto_address
  end

  def test_crypto_unknown_coin_rejected
    v = validate(crypto_coin: 'DOGE', crypto_address: 'D6exampleexampleexampleexample')
    assert_includes v, :crypto_coin
  end

  def test_crypto_valid_asset_passes
    v = validate(crypto_coin: 'USDT-TRC20', crypto_address: 'TXYZexampleexampleexampleexample12')
    assert_empty v
  end
end
