require 'prawn'
require 'prawn/table'
require 'bigdecimal'
require 'stringio'
require_relative 'fmt'

class InvoicePdf
  FONTS_DIR = File.join($root, 'public', 'fonts')
  LOGO_PATH = File.join($root, 'public', 'logo.png')
  LOGO_SIZE = 52

  ISSUER = {
    name_latin:    'IE Sergei Poljanski',
    name_alt:      'SERGEI POLJANSKI',
    name_georgian: 'ინდ. მეწარმე სერგეი პოლჯანსკი',
    tax_id:        '304813343',
    address:       [
      'Ilia and Nino Nakashidze St, N 1, Building N3, Apt N3',
      'Krtsanisi, Tbilisi, Georgia'
    ],
    email:         'ie@asxp.io',
    phone:         '+995 595 026 471',
    bank_name:     'Bank of Georgia',
    iban:          'GE53BG0000000612343299',
    swift:         'BAGAGE22'
  }.freeze

  COLOR_TEXT    = '111111'.freeze
  COLOR_MUTED   = '6F6F6F'.freeze
  COLOR_RULE    = 'DADADA'.freeze
  COLOR_ACCENT  = '1A1A1A'.freeze

  # Uniform line spacing for the FROM / BILL TO party blocks: every line gets the
  # same leading, no extra gaps between groups, so both columns read as one even
  # rhythm and line up. NAME_GAP is the one exception — a little extra air after
  # the bold company name to set it off from the details below.
  PARTY_LEADING = 2
  NAME_GAP      = 3

  # `status` overrides the status shown in the PDF (e.g. to pre-render a "paid"
  # copy before any payment date exists). Defaults to the invoice's live status.
  def self.render(invoice, status: nil)
    new(invoice, status: status).render
  end

  def initialize(invoice, status: nil)
    @invoice = invoice
    @status  = status || invoice.status
  end

  def render
    pdf = Prawn::Document.new(
      page_size: 'A4',
      margin:    [40, 50, 50, 50],
      info:      {
        Title:    "Invoice #{@invoice.number}",
        Author:   ISSUER[:name_latin],
        Creator:  'asxp.io'
      }
    )
    register_fonts(pdf)
    pdf.font('NotoSans')
    pdf.fill_color COLOR_TEXT

    draw_header(pdf)
    draw_parties(pdf)
    draw_meta(pdf)
    draw_items(pdf)
    draw_totals(pdf)
    draw_payment(pdf)
    draw_footer(pdf)

    pdf.render
  end

  private

  def register_fonts(pdf)
    pdf.font_families.update(
      'NotoSans' => {
        normal: File.join(FONTS_DIR, 'NotoSans-Regular.ttf'),
        bold:   File.join(FONTS_DIR, 'NotoSans-Bold.ttf'),
        italic: File.join(FONTS_DIR, 'NotoSans-Italic.ttf')
      },
      'NotoSansGeorgian' => {
        normal: File.join(FONTS_DIR, 'NotoSansGeorgian-Regular.ttf'),
        bold:   File.join(FONTS_DIR, 'NotoSansGeorgian-Bold.ttf')
      }
    )
    pdf.fallback_fonts = ['NotoSansGeorgian']
  end

  def draw_header(pdf)
    if File.exist?(LOGO_PATH)
      pdf.image LOGO_PATH,
                at:     [pdf.bounds.right - LOGO_SIZE, pdf.cursor],
                width:  LOGO_SIZE,
                height: LOGO_SIZE
    end
    pdf.font_size(20) { pdf.text 'INVOICE', style: :bold, character_spacing: 2 }
    pdf.move_down 2
    pdf.fill_color COLOR_MUTED
    pdf.font_size(9) { pdf.text @invoice.number }
    pdf.fill_color COLOR_TEXT
    pdf.move_down 16
    pdf.stroke_color COLOR_RULE
    pdf.stroke_horizontal_rule
    pdf.move_down 16
  end

  def draw_parties(pdf)
    top_y = pdf.y
    right = 285
    col_w = 250

    pdf.bounding_box([0, pdf.cursor], width: col_w) do
      draw_party_label(pdf, 'FROM')
      pdf.font_size(11) { pdf.text ISSUER[:name_latin], style: :bold, leading: PARTY_LEADING }
      pdf.move_down NAME_GAP
      pdf.font_size(9) do
        lines = [
          ISSUER[:name_georgian],
          *ISSUER[:address],
          "Tax ID: #{ISSUER[:tax_id]}",
          ISSUER[:email],
          ISSUER[:phone]
        ]
        pdf.text lines.join("\n"), leading: PARTY_LEADING
      end
    end
    from_y = pdf.y

    pdf.y = top_y
    pdf.bounding_box([right, pdf.cursor], width: pdf.bounds.right - right) do
      draw_party_label(pdf, 'BILL TO')
      pdf.font_size(11) { pdf.text @invoice.client_name, style: :bold, leading: PARTY_LEADING }
      pdf.move_down NAME_GAP
      pdf.font_size(9) do
        lines = [@invoice.client_email]
        lines << @invoice.client_address unless @invoice.client_address.to_s.strip.empty?
        pdf.text lines.join("\n"), leading: PARTY_LEADING
      end
    end
    bill_y = pdf.y

    pdf.y = [from_y, bill_y].min
    pdf.move_down 24
  end

  def draw_party_label(pdf, label)
    pdf.fill_color COLOR_MUTED
    pdf.font_size(8) { pdf.text label, character_spacing: 1.5 }
    pdf.fill_color COLOR_TEXT
    pdf.move_down 8
  end

  def draw_meta(pdf)
    pdf.stroke_color COLOR_RULE
    pdf.stroke_horizontal_rule
    pdf.move_down 8

    cells = [
      ['ISSUED',   @invoice.issued_on.strftime('%Y-%m-%d')],
      ['DUE',      @invoice.due_on.strftime('%Y-%m-%d')],
      ['CURRENCY', @invoice.currency],
      ['STATUS',   @status.upcase]
    ]
    col_w = pdf.bounds.width / cells.size.to_f
    top   = pdf.cursor

    cells.each_with_index do |(label, value), i|
      pdf.bounding_box([i * col_w, top], width: col_w) do
        pdf.fill_color COLOR_MUTED
        pdf.font_size(7) { pdf.text label, character_spacing: 1.2 }
        pdf.fill_color COLOR_TEXT
        pdf.move_down 2
        pdf.font_size(10) { pdf.text value, style: :bold }
      end
    end

    # The cells are absolutely-positioned boxes that don't advance the outer
    # cursor, so reserve the row height manually. Tuned (measured from the
    # rendered PNG) so the gap below the values matches the ~10pt gap above the
    # labels rather than ballooning to ~29pt.
    pdf.move_down 9
    pdf.stroke_horizontal_rule
    pdf.move_down 16
  end

  def draw_items(pdf)
    header = ['Description', 'Qty', "Unit (#{@invoice.currency})", "Amount (#{@invoice.currency})"]
    rows = @invoice.items_array.map do |i|
      qty  = BigDecimal(i['qty'].to_s)
      unit = BigDecimal(i['unit_price'].to_s)
      [i['description'], fmt_qty(qty), fmt_money(unit), fmt_money(qty * unit)]
    end
    table_data = [header] + rows

    pdf.table(table_data, header: true, width: pdf.bounds.width,
              column_widths: { 0 => pdf.bounds.width - 270, 1 => 60, 2 => 100, 3 => 110 }) do
      cells.borders = [:bottom]
      cells.border_color = COLOR_RULE
      cells.padding = [8, 8, 8, 8]
      cells.size = 9
      row(0).font_style = :bold
      row(0).text_color = COLOR_MUTED
      row(0).size = 8
      row(0).background_color = 'FAFAFA'
      columns(1..3).align = :right
    end
    pdf.move_down 8
  end

  def draw_totals(pdf)
    total = @invoice.total
    rows = [
      ['Subtotal', "#{@invoice.currency} #{fmt_money(total)}"],
      ['Total',    "#{@invoice.currency} #{fmt_money(total)}"]
    ]
    if @invoice.currency != 'GEL'
      rows << ["In GEL (rate #{fmt_rate(@invoice.gel_rate)})", "GEL #{fmt_money(@invoice.total_gel)}"]
    end

    pdf.bounding_box([pdf.bounds.right - 270, pdf.cursor], width: 270) do
      pdf.table(rows, cell_style: { borders: [], padding: [4, 0, 4, 0], size: 10 },
                column_widths: { 0 => 130, 1 => 140 }) do
        columns(0).text_color = COLOR_MUTED
        columns(1).align = :right
        row(1).font_style = :bold
        row(1).text_color = COLOR_ACCENT
        row(1).size = 12
      end
    end
    pdf.move_down 30
  end

  def draw_payment(pdf)
    pdf.fill_color COLOR_MUTED
    pdf.font_size(8) { pdf.text 'PAYMENT', character_spacing: 1.5 }
    pdf.fill_color COLOR_TEXT
    pdf.move_down 4
    pdf.font_size(9) do
      pdf.text "Bank: #{ISSUER[:bank_name]}"
      pdf.text "IBAN: #{ISSUER[:iban]}"
      pdf.text "SWIFT: #{ISSUER[:swift]}"
      pdf.text "Beneficiary: #{ISSUER[:name_latin]}"
    end

    draw_ltc(pdf) if @invoice.respond_to?(:ltc?) && @invoice.ltc?

    unless @invoice.notes.to_s.strip.empty?
      pdf.move_down 14
      pdf.fill_color COLOR_MUTED
      pdf.font_size(8) { pdf.text 'NOTES', character_spacing: 1.5 }
      pdf.fill_color COLOR_TEXT
      pdf.move_down 4
      pdf.font_size(9) { pdf.text @invoice.notes }
    end
  end

  def draw_ltc(pdf)
    amount  = @invoice.ltc_amount_due
    qr_size = 78

    pdf.move_down 12
    pdf.fill_color COLOR_MUTED
    pdf.font_size(8) { pdf.text 'PAY IN LITECOIN (LTC)', character_spacing: 1.5 }
    pdf.fill_color COLOR_TEXT
    pdf.move_down 4

    # Fixed-height row: QR on the right (drawn with float so it doesn't advance
    # the cursor), text column on the left. The outer bounding_box of height
    # qr_size leaves the cursor exactly below the row when it ends.
    qr_bytes = LtcQr.png(@invoice.ltc_address, amount)
    pdf.bounding_box([0, pdf.cursor], width: pdf.bounds.width, height: qr_size) do
      pdf.float do
        pdf.bounding_box([pdf.bounds.right - qr_size, pdf.bounds.top], width: qr_size, height: qr_size) do
          pdf.image StringIO.new(qr_bytes), width: qr_size, height: qr_size
        end
      end

      pdf.bounding_box([0, pdf.bounds.top], width: pdf.bounds.width - qr_size - 16) do
        pdf.font_size(9) do
          if amount
            pdf.text "Amount: #{fmt_ltc(amount)} LTC", style: :bold
            if @invoice.ltc_rate
              pdf.fill_color COLOR_MUTED
              pdf.text "(rate 1 LTC = #{fmt_rate(@invoice.ltc_rate)} #{@invoice.currency} at issue)", size: 8
              pdf.fill_color COLOR_TEXT
            end
            pdf.move_down 3
          end
          pdf.text 'Address:'
          pdf.font_size(8) { pdf.text @invoice.ltc_address }
          pdf.move_down 3
          pdf.fill_color COLOR_MUTED
          pdf.font_size(7) { pdf.text 'Scan the QR with any Litecoin wallet to prefill the payment.' }
          pdf.fill_color COLOR_TEXT
        end
      end
    end
  end

  def draw_footer(pdf)
    # Static left-side line repeats on every page.
    pdf.repeat(:all) do
      pdf.canvas do
        pdf.fill_color COLOR_MUTED
        pdf.font_size(8) do
          pdf.draw_text(
            "#{ISSUER[:name_latin]} · Tax ID #{ISSUER[:tax_id]} · Small Business (1% turnover tax)",
            at: [50, 25]
          )
        end
        pdf.fill_color COLOR_TEXT
      end
    end

    # Page number must be stamped per page: inside repeat(:all), pdf.page_number
    # resolves to the final page count for every page. number_pages substitutes
    # <page>/<total> at finalization, once per actual page.
    pdf.number_pages(
      'Page <page> of <total>',
      at:      [pdf.bounds.right - 90, -25],
      width:   90,
      align:   :right,
      size:    8,
      color:   COLOR_MUTED
    )
  end

  def fmt_money(value)
    BigDecimal(value.to_s).round(2).to_s('F').then { |s| with_thousands(s) }
  end

  def fmt_ltc(value)
    Fmt.ltc(value)
  end

  def fmt_rate(value, min_dp: 4)
    Fmt.rate(value, min_dp: min_dp)
  end

  def fmt_qty(value)
    bd = BigDecimal(value.to_s)
    bd.frac.zero? ? bd.to_i.to_s : bd.to_s('F')
  end

  def with_thousands(numstr)
    int, frac = numstr.split('.')
    int = Fmt.group(int)
    frac ? "#{int}.#{frac.ljust(2, '0')[0, 2]}" : "#{int}.00"
  end
end
