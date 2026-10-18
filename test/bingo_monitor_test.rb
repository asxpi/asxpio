require_relative 'test_helper'
require 'socket'

class BingoMonitorTest < Minitest::Test
  include Rack::Test::Methods
  include AdminLogin

  def app = AsxpioWeb

  def setup
    skip 'TEST_DATABASE_URL not set' unless TestDb.available?
    db = DB.connection
    %i[bingo_monitor_buckets bingo_monitor_samples bingo_monitor_targets bingo_incidents bingo_datacenters].each { |t| db[t].delete }
    @dc = Bingo::Datacenter.create(slug: 'dc-a', position: 1, name_ru: 'ЦОД А', city_ru: 'Москва', operator: 'Op')
  end

  def test_probe_counts_handshake_and_refusal_as_answered
    server = TCPServer.new('127.0.0.1', 0)
    open_port = server.addr[1]
    assert_kind_of Integer, Bingo::Monitor.probe('127.0.0.1', open_port)
    server.close
    assert_kind_of Integer, Bingo::Monitor.probe('127.0.0.1', open_port), 'refused = host answered'
    assert_nil Bingo::Monitor.probe('no-such-host.invalid', 443)
  end

  def test_record_folds_rounds_into_one_bucket
    a = Bingo::Monitor::Target.create(datacenter_id: @dc.id, host: 'a', port: 443)
    b = Bingo::Monitor::Target.create(datacenter_id: @dc.id, host: 'b', port: 443)
    c = Bingo::Monitor::Target.create(datacenter_id: nil, host: 'ctl', port: 80)
    t0 = Time.utc(2026, 10, 18, 4, 0, 30)
    Bingo::Monitor.record!([[a, 10], [b, nil], [c, 5]], at: t0)
    Bingo::Monitor.record!([[a.refresh, 20], [b.refresh, 30], [c.refresh, nil]], at: t0 + 60)

    s = DB.connection[:bingo_monitor_samples].first
    assert_equal [Time.utc(2026, 10, 18, 4, 0), 4, 3, 60], s.values_at(:bucket_at, :checks, :ok, :rtt_ms_sum)
    bk = DB.connection[:bingo_monitor_buckets].first
    assert_equal [2, 2, 1], bk.values_at(:rounds, :control_checks, :control_ok)
    b.refresh
    assert b.last_ok
    assert_equal t0 + 60, b.last_change_at
    assert_equal t0, a.refresh.last_change_at, 'unchanged state keeps its time'
  end

  def test_prune_drops_old_buckets
    Bingo::Monitor.record!([], at: Time.utc(2026, 1, 1))
    Bingo::Monitor.record!([], at: Time.utc(2026, 10, 18))
    Bingo::Monitor.prune!(Time.utc(2026, 10, 18))
    assert_equal [Time.utc(2026, 10, 18)], DB.connection[:bingo_monitor_buckets].select_map(:bucket_at)
  end

  def test_parse_bulk_lines
    attrs, errors = Bingo::Monitor.parse(<<~TXT)
      # comment
      dc-a 192.0.2.1:80 https://example.com/ips Test IP one
      _control lg.example.ru
      dc-zzz 192.0.2.2
      dc-a 192.0.2.3 not-a-url
    TXT
    assert_equal({ datacenter_id: @dc.id, host: '192.0.2.1', port: 80, source_url: 'https://example.com/ips', label: 'Test IP one' }, attrs[0])
    assert_equal({ datacenter_id: nil, host: 'lg.example.ru', port: 443, source_url: nil, label: nil }, attrs[1])
    assert_equal ['line 4: unknown slug "dc-zzz"', 'line 5: source must be an http(s) URL'], errors
  end

  def test_admin_adds_and_lists_targets
    admin_login!
    get '/admin/bingo/monitor'
    token = last_response.body[/name="authenticity_token" value="([^"]+)"/, 1]
    post '/admin/bingo/monitor', authenticity_token: token, targets: "dc-a 192.0.2.1:80 https://example.com/ips Test IP\n"
    assert_equal 1, Bingo::Monitor::Target.count
    get '/admin/bingo/monitor'
    assert_includes last_response.body, '192.0.2.1:80'
    refute_includes last_response.body, 'dc-a</p>', 'monitored site leaves the unmonitored list'
  end
end
