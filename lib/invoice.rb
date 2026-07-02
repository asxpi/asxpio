require 'sequel'
require 'securerandom'
require 'json'
require 'bigdecimal'
require_relative 'crypto_asset'

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

  # Both status variants are pre-rendered at creation; `pdf_key` is the base
  # path (no suffix). The download route picks a variant by current status.
  def pdf_key_for(status)
    base = pdf_key.sub(/\.pdf\z/, '')
    "#{base}-#{status}.pdf"
  end

  def current_pdf_key
    pdf_key_for(status)
  end

  def total
    BigDecimal(subtotal.to_s)
  end

  def total_gel
    (total * BigDecimal(gel_rate.to_s)).round(2)
  end

  def crypto?
    !crypto_address.to_s.strip.empty?
  end

  # The crypto amount to display / encode in the QR. Returns nil when no
  # amount is known (address-only invoice).
  def crypto_amount_due
    return nil unless crypto?
    return BigDecimal(crypto_amount.to_s) unless crypto_amount.nil?
    return nil if crypto_rate.nil? || BigDecimal(crypto_rate.to_s).zero?
    (total / BigDecimal(crypto_rate.to_s)).round(8)
  end

  class << self
    # Max is taken over the numeric suffix, not the string: past 9999 the
    # 5-digit numbers would sort below INV-YYYY-9999 lexically and the
    # allocator would hand out duplicates.
    def allocate_number(year = Date.today.year)
      prefix = "INV-#{year}-"
      last   = where(Sequel.like(:number, "#{prefix}%"))
                 .max(Sequel.cast(Sequel.function(:split_part, :number, '-', 3), Integer))
      format("#{prefix}%04d", (last || 0) + 1)
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
      apply_crypto(invoice, params, subtotal)
      invoice.uuid = SecureRandom.uuid
      invoice
    end

    private

    # Crypto is opt-in: only populated when an address is given. Rate and
    # amount are both optional; if amount is blank but rate is present,
    # derive it.
    def apply_crypto(invoice, params, subtotal)
      address = params[:crypto_address].to_s.strip
      return if address.empty?

      coin = params[:crypto_coin].to_s.upcase
      CryptoAsset.valid?(coin) or raise ArgumentError, "Unknown coin: #{coin}"

      invoice.crypto_coin = coin
      invoice.crypto_address = address

      rate = decimal_or_nil(params[:crypto_rate])
      invoice.crypto_rate = rate

      amount = decimal_or_nil(params[:crypto_amount])
      amount ||= (subtotal / rate).round(8) if rate && !rate.zero?
      invoice.crypto_amount = amount
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
