require 'bigdecimal'

# Figures for /admin/invoices/stats. Money is compared in GEL at each
# invoice's captured rate (total_gel), the one currency every invoice has.
# Cancelled invoices count only in `cancelled`.
class InvoiceStats
  attr_reader :year, :invoices

  def initialize(invoices, year: nil)
    @all      = invoices
    @year     = year
    @invoices = year ? invoices.select { |i| i.issued_on.year == year } : invoices
  end

  def years
    @all.map { |i| i.issued_on.year }.uniq.sort.reverse
  end

  def live      = @live ||= invoices.reject(&:cancelled?)
  def paid      = live.select(&:paid?)
  def unpaid    = live.reject(&:paid?)
  def overdue   = unpaid.select { |i| i.due_on < Date.today }
  def cancelled = invoices.select(&:cancelled?)

  def gel(list) = list.sum(BigDecimal('0')) { |i| i.total_gel }

  def avg_days_to_pay
    days = paid.map { |i| (i.paid_at.to_date - i.issued_on).to_i }
    days.empty? ? nil : (days.sum.to_f / days.size).round
  end

  # currency => { invoiced:, paid:, outstanding: } in the invoice currency
  def by_currency
    live.group_by(&:currency).sort.to_h.transform_values do |l|
      { invoiced: l.sum(BigDecimal('0'), &:total),
        paid: l.select(&:paid?).sum(BigDecimal('0'), &:total),
        outstanding: l.reject(&:paid?).sum(BigDecimal('0'), &:total) }
    end
  end

  # [[Date (1st of month), issued count, invoiced GEL, received GEL]], oldest
  # first. Received is by payment date, so it can fall in a later month.
  def monthly
    months =
      if year then (1..12).map { |m| Date.new(year, m, 1) }
      else
        first = (live.map(&:issued_on) + paid.map { |i| i.paid_at.to_date }).min or return []
        m = Date.new(first.year, first.month, 1)
        last = Date.new(Date.today.year, Date.today.month, 1)
        [].tap { |a| (a << m; m = m.next_month) while m <= last }
      end
    pool_paid = year ? @all.reject(&:cancelled?).select(&:paid?) : paid
    months.map do |m|
      issued   = live.select { |i| i.issued_on.year == m.year && i.issued_on.month == m.month }
      received = pool_paid.select { |i| d = i.paid_at.to_date; d.year == m.year && d.month == m.month }
      [m, issued.size, gel(issued), gel(received)]
    end
  end

  def top_clients(n = 5)
    live.group_by(&:client_name).map { |c, l| [c, l.size, gel(l)] }.sort_by { |_, _, g| -g }.first(n)
  end

  # [[ticker, name, invoices]] — name from the invoices' own snapshot.
  def crypto_usage
    live.select(&:crypto?).group_by(&:crypto_coin)
        .map { |c, l| [c, l.filter_map(&:crypto_name).last || c, l.size] }.sort_by { |_, _, n| -n }
  end
end
