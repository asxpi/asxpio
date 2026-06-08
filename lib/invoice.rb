require 'sequel'
require 'securerandom'
require 'json'
require 'bigdecimal'

class Invoice < Sequel::Model(:invoices)
  CURRENCIES = %w[USD EUR GEL].freeze

  plugin :json_serializer

  def items_array
    raw = self[:items]
    raw.is_a?(String) ? JSON.parse(raw) : raw
  end

  def items_array=(arr)
    self[:items] = Sequel.pg_jsonb_wrap(arr)
  rescue NoMethodError
    self[:items] = arr.to_json
  end

  def paid?
    !paid_at.nil?
  end

  def status
    paid? ? 'paid' : 'pending'
  end

  def total
    BigDecimal(subtotal.to_s)
  end

  def total_gel
    (total * BigDecimal(gel_rate.to_s)).round(2)
  end

  def ltc?
    !ltc_address.to_s.strip.empty?
  end

  # The LTC amount to display / encode in the QR. Returns nil when no amount
  # is known (address-only invoice).
  def ltc_amount_due
    return nil unless ltc?
    return BigDecimal(ltc_amount.to_s) unless ltc_amount.nil?
    return nil if ltc_rate.nil? || BigDecimal(ltc_rate.to_s).zero?
    (total / BigDecimal(ltc_rate.to_s)).round(8)
  end

  class << self
    def allocate_number(year = Date.today.year)
      prefix = "INV-#{year}-"
      last   = where(Sequel.like(:number, "#{prefix}%"))
                 .order(Sequel.desc(:number))
                 .get(:number)
      n = last ? last.split('-').last.to_i + 1 : 1
      format("#{prefix}%04d", n)
    end

    def build(params)
      items = normalize_items(params.fetch(:items))
      subtotal = items.sum { |i| BigDecimal(i['qty'].to_s) * BigDecimal(i['unit_price'].to_s) }

      invoice = Invoice.new(
        number:         allocate_number,
        client_name:    params.fetch(:client_name).to_s.strip,
        client_email:   params.fetch(:client_email).to_s.strip,
        client_address: params[:client_address].to_s.strip,
        currency:       normalize_currency(params.fetch(:currency)),
        gel_rate:       BigDecimal(params.fetch(:gel_rate).to_s),
        subtotal:       subtotal,
        items:          items.to_json,
        issued_on:      parse_date(params[:issued_on]) || Date.today,
        due_on:         parse_date(params[:due_on])    || (Date.today + 14),
        notes:          params[:notes].to_s.strip,
        pdf_key:        '',
        created_at:     Time.now.utc
      )
      apply_ltc(invoice, params, subtotal)
      invoice.uuid = SecureRandom.uuid
      invoice
    end

    private

    # LTC is opt-in: only populated when an address is given. Rate and amount
    # are both optional; if amount is blank but rate is present, derive it.
    def apply_ltc(invoice, params, subtotal)
      address = params[:ltc_address].to_s.strip
      return if address.empty?

      invoice.ltc_address = address

      rate = decimal_or_nil(params[:ltc_rate])
      invoice.ltc_rate = rate

      amount = decimal_or_nil(params[:ltc_amount])
      amount ||= (subtotal / rate).round(8) if rate && !rate.zero?
      invoice.ltc_amount = amount
    end

    def decimal_or_nil(raw)
      s = raw.to_s.strip
      return nil if s.empty?
      BigDecimal(s)
    rescue ArgumentError
      nil
    end

    def normalize_currency(c)
      c = c.to_s.upcase
      CURRENCIES.include?(c) or raise ArgumentError, "Unsupported currency: #{c}"
      c
    end

    def normalize_items(raw)
      Array(raw).filter_map do |row|
        desc = row['description'].to_s.strip
        next if desc.empty?
        qty  = BigDecimal(row['qty'].to_s.empty?        ? '0' : row['qty'].to_s)
        unit = BigDecimal(row['unit_price'].to_s.empty? ? '0' : row['unit_price'].to_s)
        { 'description' => desc, 'qty' => qty.to_s('F'), 'unit_price' => unit.to_s('F') }
      end
    end

    def parse_date(s)
      return nil if s.nil? || s.to_s.strip.empty?
      Date.parse(s.to_s)
    rescue ArgumentError
      nil
    end
  end
end
