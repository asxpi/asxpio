require_relative 'test_helper'
require 'minitest/mock'

class BingoTest < Minitest::Test
  include Rack::Test::Methods
  include AdminLogin

  # Minimal well-formed JPEG: SOI, start-of-scan, data, EOI.
  JPEG = ("\xFF\xD8\xFF\xDA".b + [8].pack('n') + "\1\2\3\4\5\6data\xFF\xD9".b).freeze

  def app = AsxpioWeb

  def setup
    skip 'TEST_DATABASE_URL not set' unless TestDb.available?
    DB.connection[:bingo_incidents].delete
    DB.connection[:bingo_datacenters].delete
    @dcs = (1..25).map do |n|
      Bingo::Datacenter.create(slug: "dc-#{n}", position: n, name_ru: "ЦОД #{n}", name_en: ("DC #{n}" if n == 1),
                               city_ru: 'Москва', city_en: 'Moscow', operator: 'Op', mw: n.to_s)
    end
  end


  def hit!(idx, kind: 'outage')
    Bingo::Incident.create(datacenter_id: @dcs[idx].id, occurred_on: Date.today, kind: kind,
                           title_ru: "Авария #{idx}", title_uk: "Аварія #{idx}")
  end



  def test_board_detects_lines
    (0..4).each { |i| hit!(i) }     # top row
    [6, 12, 18, 24].each { |i| hit!(i) } # + main diagonal (0 already hit)
    board = Bingo::Board.load
    assert_equal 2, board.wins.size
  end

  def test_photo_store
    key = Bingo::Photo.store('dc-1', JPEG)
    assert_match %r{\Abingo/dc-1-[0-9a-f]{8}\.jpg\z}, key
    assert_raises(Bingo::Photo::Error) { Bingo::Photo.read('..%2Finvoices%2Fx.pdf') }
  end

  def test_strips_jpeg_exif
    exif = "\xFF\xE1".b + [17].pack('n') + "Exif\0\0GPSDATA!!".b
    jfif = "\xFF\xE0".b + [16].pack('n') + "JFIF\0".b + ("\0" * 9).b
    scan = "\xFF\xDA".b + [8].pack('n') + "\1\2\3\4\5\6pixels\xFF\xD9".b
    out = Bingo::Photo.strip_metadata("\xFF\xD8".b + jfif + exif + scan, 'jpg')
    refute_includes out, 'GPSDATA'
    assert_equal "\xFF\xD8".b + jfif + scan, out
  end

  def test_strips_png_text_chunks
    chunk = ->(type, data) { [data.bytesize].pack('N') + type + data + "\0\0\0\0".b }
    sig  = "\x89PNG\r\n\x1A\n".b
    ihdr = chunk.('IHDR', "\0" * 13)
    out  = Bingo::Photo.strip_metadata(sig + ihdr + chunk.('eXIf', 'GPS') + chunk.('tEXt', 'k\0v') + chunk.('IEND', ''), 'png')
    assert_equal sig + ihdr + chunk.('IEND', ''), out
  end

  def test_strips_webp_exif
    vp8x = 'VP8X'.b + [10].pack('V') + [0x08 | 0x10].pack('C') + ("\0" * 9).b # EXIF + alpha flags
    img  = 'VP8L'.b + [5].pack('V') + "abcde\0".b
    exif = 'EXIF'.b + [3].pack('V') + "GPS\0".b
    body = vp8x + img + exif
    out  = Bingo::Photo.strip_metadata('RIFF'.b + [body.bytesize + 4].pack('V') + 'WEBPh'.b[0, 4] + body, 'webp')
    refute_includes out, 'GPS'
    assert_equal 0x10, out.getbyte(20) # alpha kept, EXIF flag cleared
    assert_equal out.bytesize - 8, out.byteslice(4, 4).unpack1('V')
  end

  def test_operational_view_skips_construction_projects
    @dcs[0].update(status: 'building')
    Bingo::Datacenter.create(slug: 'dc-26', position: 26, name_ru: 'ЦОД 26', city_ru: 'Москва', operator: 'Op', mw: '1')
    all = Bingo::Board.load
    op  = Bingo::Board.load('operational')
    assert_includes all.cells.map(&:slug), 'dc-1'
    refute_includes op.cells.map(&:slug), 'dc-1'
    assert_equal 'dc-26', op.cells.last.slug          # reserve moves up to fill the card
    assert_equal 25, op.cells.size
  end

  def test_operational_view_recomputes_lines
    (1..4).each { |i| hit!(i) }                       # row 1 minus dc-1
    @dcs[0].update(status: 'building')
    Bingo::Datacenter.create(slug: 'dc-26', position: 26, name_ru: 'ЦОД 26', city_ru: 'Москва', operator: 'Op')
    assert_equal 0, Bingo::Board.load.wins.size        # dc-1 not hit
    hit!(5)                                           # dc-6 now sits at index 4 in operational view
    assert_equal 1, Bingo::Board.load('operational').wins.size
  end

  def test_admin_saves_capacity_type_and_planned
    token = admin_token("/admin/bingo/dc/#{@dcs[0].id}")
    post "/admin/bingo/dc/#{@dcs[0].id}", dc_params(authenticity_token: token, name_ru: 'ЦОД 1', status: 'planned', mw_type: 'connected'), admin_env
    @dcs[0].refresh
    assert @dcs[0].planned?
    assert_equal 'connected', @dcs[0].mw_type
    post "/admin/bingo/dc/#{@dcs[0].id}", dc_params(authenticity_token: token, name_ru: 'ЦОД 1', mw_type: 'bogus'), admin_env
    assert_nil @dcs[0].refresh.mw_type
  end

  def test_provider_guessed_on_create
    dc = Bingo::Datacenter.create(slug: 'ya-x', position: 30, name_ru: 'Я', city_ru: 'М', operator: 'Яндекс')
    assert_equal 'yandex', dc.provider
    assert_nil Bingo::Datacenter.create(slug: 'zz', position: 31, name_ru: 'Z', city_ru: 'М', operator: 'Op').provider
  end

  def test_provider_filter_keeps_a_5x5_card
    @dcs.first(3).each { |d| d.update(provider: 'yandex') }
    @dcs[3].update(provider: 'rtk')
    hit!(0)
    board = Bingo::Board.load('operational', providers: %w[yandex rtk])
    assert_equal %w[dc-1 dc-2 dc-3 dc-4], board.cells.map(&:slug)
  end

  def test_filtered_card_still_scores_lines
    @dcs.first(5).each { |d| d.update(provider: 'ixcellerate') }
    (0..4).each { |i| hit!(i) }
    assert_equal 1, Bingo::Board.load('operational', providers: ['ixcellerate']).wins.size
  end

  def test_admin_saves_provider
    token = admin_token("/admin/bingo/dc/#{@dcs[0].id}")
    post "/admin/bingo/dc/#{@dcs[0].id}", dc_params(authenticity_token: token, name_ru: 'ЦОД 1', status: 'operational', provider: 'selectel'), admin_env
    assert_equal 'selectel', @dcs[0].refresh.provider
    post "/admin/bingo/dc/#{@dcs[0].id}", dc_params(authenticity_token: token, name_ru: 'ЦОД 1', status: 'operational', provider: 'nope'), admin_env
    assert_nil @dcs[0].refresh.provider
  end

  def test_updated_on_follows_edits_and_deletes
    old = Time.utc(2026, 1, 1)
    DB.connection[:bingo_datacenters].update(created_at: old, updated_at: old)
    assert_equal old, Bingo::Board.load.updated_on
    @dcs[5].refresh.update(name_en: 'Renamed')
    assert_operator Bingo::Board.load.updated_on, :>, old
    DB.connection[:bingo_datacenters].update(updated_at: old)
    inc = hit!(2)
    DB.connection[:bingo_incidents].update(created_at: old, updated_at: old)
    inc.refresh.destroy
    assert_operator Bingo::Board.load.updated_on, :>, old
  end

  def test_dc_about_text
    token = admin_token("/admin/bingo/dc/#{@dcs[1].id}")
    post "/admin/bingo/dc/#{@dcs[1].id}", dc_params(authenticity_token: token, about_en: "First <b>para</b>.\r\n\r\nSecond."), admin_env
    assert_equal "First <b>para</b>.\r\n\r\nSecond.", @dcs[1].refresh.about_en
    assert_equal ['First <b>para</b>.', 'Second.'], @dcs[1].about('en')
    assert_empty @dcs[1].about('ru') # no fallback across languages
  end

  def with_env(vars)
    old = vars.to_h { |k, _| [k, ENV[k]] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| ENV[k] = v }
  end

  def test_indexnow_ping
    assert_nil Bingo::IndexNow.ping([@dcs[0]]) # no key: nothing sent
    sent = []
    with_env('INDEXNOW_KEY' => '0123456789abcdef', 'BINGO_HOST' => 'bingo.example') do
      Bingo::IndexNow.stub(:deliver, ->(body) { sent << JSON.parse(body) }) do
        Bingo::IndexNow.ping([@dcs[0]]).join
      end
    end
    body = sent.fetch(0)
    assert_equal 'bingo.example', body['host']
    assert_equal 'https://bingo.example/0123456789abcdef.txt', body['keyLocation']
    assert_equal %w[/ru /en /uk /ru/dc/dc-1 /en/dc/dc-1 /uk/dc/dc-1].map { |p| "https://bingo.example#{p}" }, body['urlList']
  end

  def test_admin_incident_pings_indexnow
    token = admin_token
    pinged = []
    Bingo::IndexNow.stub(:ping, ->(dcs) { pinged << dcs.map(&:slug) }) do
      post '/admin/bingo/incidents', { authenticity_token: token, datacenter_id: @dcs[2].id, occurred_on: '2026-10-01',
                                       kind: 'fire', title_ru: 'Пожар' }, admin_env
      post "/admin/bingo/incidents/#{Bingo::Incident.first.id}/delete", { authenticity_token: token }, admin_env
    end
    assert_equal [['dc-3'], ['dc-3']], pinged
  end

  def test_resize_produces_small_webp
    skip 'ImageMagick not available' unless system(Bingo::Photo::CONVERT, '-version', out: File::NULL, err: File::NULL)
    png, = Open3.capture2(Bingo::Photo::CONVERT, '-size', '2000x1000', 'gradient:red-blue', 'png:-', binmode: true)
    out = Bingo::Photo.resize(png.b, 'png', 480)
    assert_equal 'webp', Bingo::Photo.sniff(out)
    dims, = Open3.capture2(Bingo::Photo::CONVERT, 'webp:-', '-format', '%wx%h', 'info:', stdin_data: out, binmode: true)
    assert_equal '480x240', dims
    jpg = Bingo::Photo.og_crop(png.b, 'png')
    assert_equal 'jpg', Bingo::Photo.sniff(jpg)
    dims, = Open3.capture2(Bingo::Photo::CONVERT, 'jpeg:-', '-format', '%wx%h', 'info:', stdin_data: jpg, binmode: true)
    assert_equal '1200x630', dims
  end

  def test_sniff_accepts_utf8_tagged_bytes
    assert_equal 'jpg', Bingo::Photo.sniff(JPEG.dup.force_encoding('UTF-8'))
  end

  def test_rebuild_from_utf8_s3_body
    skip 'ImageMagick not available' unless system(Bingo::Photo::CONVERT, '-version', out: File::NULL, err: File::NULL)
    png, = Open3.capture2(Bingo::Photo::CONVERT, '-size', '800x600', 'gradient:red-blue', 'png:-', binmode: true)
    Aws.config[:s3] = { stub_responses: { get_object: { body: png.dup.force_encoding('UTF-8') } } }
    S3.instance_variable_set(:@client, nil)
    @dcs[0].update(photo_key: 'bingo/dc-1-0123abcd.png')
    Bingo::Photo.rebuild(@dcs[0])
    assert @dcs[0].refresh.photo_variants
    assert @dcs[0].photo_og
    assert_equal 'dc-1-0123abcd-og.jpg', @dcs[0].og_file
  ensure
    Aws.config[:s3] = { stub_responses: true }
    S3.instance_variable_set(:@client, nil)
  end

  def test_photo_rejects_non_images
    assert_raises(Bingo::Photo::Error) { Bingo::Photo.store('dc-1', '<html>') }
  end

  def test_admin_requires_login
    get '/admin/bingo'
    assert_equal 302, last_response.status
  end

  def test_admin_dashboard
    hit!(2)
    DB.connection[:invoices].delete
    inv = Invoice.build(client_name: 'ACME', client_email: 'b@example.com', currency: 'EUR', gel_rate: '3.05',
                        due_on: (Date.today - 1).to_s,
                        items: [{ 'description' => 'work', 'qty' => '2', 'unit_price' => '50' }])
    inv.pdf_key = "invoices/#{inv.number}-#{inv.uuid}.pdf"
    inv.save_changes
    get '/admin', {}, admin_env
    assert last_response.ok?, last_response.status.to_s
    body = last_response.body
    assert_includes body, '<h1>Dashboard</h1>'
    assert_includes body, '1/25'                       # crossed out
    assert_includes body, 'Авария 2'                   # latest incident
    assert_includes body, 'href="/admin/invoices/new"'
    assert_includes body, 'class="active">dashboard'
    assert_includes body, inv.number
    assert_includes body, 'EUR 100.00'                 # outstanding total
    assert_match %r{<b>1</b><span>overdue</span>}, body
  ensure
    DB.connection[:invoices].delete
  end

  def test_admin_records_and_deletes_incident
    get '/admin/bingo', {}, admin_env
    assert last_response.ok?
    token = last_response.body[/name="authenticity_token" value="([^"]+)"/, 1]

    post '/admin/bingo/incidents', { authenticity_token: token, datacenter_id: @dcs[3].id,
                                     occurred_on: '2026-10-01', kind: 'fire', title_ru: 'Пожар',
                                     url: 'https://example.com/news' }, admin_env
    assert_equal 302, last_response.status
    inc = Bingo::Incident.first
    assert_equal 'fire', inc.kind
    assert_equal @dcs[3].id, inc.datacenter_id

    post '/admin/bingo/incidents', { authenticity_token: token, datacenter_id: @dcs[3].id,
                                     occurred_on: '2026-10-01', kind: 'fire', title_ru: 'x',
                                     url: 'javascript:alert(1)' }, admin_env
    assert_equal 1, Bingo::Incident.count

    post "/admin/bingo/incidents/#{inc.id}/delete", { authenticity_token: token }, admin_env
    assert_equal 0, Bingo::Incident.count
  end

  def test_admin_edits_datacenter
    get "/admin/bingo/dc/#{@dcs[0].id}", {}, admin_env
    assert last_response.ok?
    token = last_response.body[/name="authenticity_token" value="([^"]+)"/, 1]
    post "/admin/bingo/dc/#{@dcs[0].id}", { authenticity_token: token, name_ru: 'Новое', city_ru: 'Калуга',
                                            name_uk: 'Нове', operator: 'Yandex', mw: '63', status: 'building',
                                            year: '2027', position: '1' }, admin_env
    @dcs[0].refresh
    assert_equal 'Нове', @dcs[0].name_uk
    assert @dcs[0].building?
    assert_equal 2027, @dcs[0].year
  end

  def admin_token(path = '/admin/bingo')
    get path, {}, admin_env
    last_response.body[/name="authenticity_token" value="([^"]+)"/, 1]
  end

  def dc_params(extra = {})
    { name_ru: 'IXcellerate MOS7', city_ru: 'Москва', operator: 'IXcellerate', mw: '34', status: 'building' }.merge(extra)
  end

  def test_mw_value
    assert_equal 64.0, Bingo.mw_value('64')
    assert_equal 30.0, Bingo.mw_value('25–30')
    assert_equal 13.7, Bingo.mw_value('13,7')
    assert_equal 40.0, Bingo.mw_value('>40')
    assert_nil Bingo.mw_value('')
  end

  def test_admin_adds_datacenter_at_position
    token = admin_token('/admin/bingo/dc/new')
    post '/admin/bingo/dc', dc_params(authenticity_token: token, slug: 'ix-mos7', position: '9'), admin_env
    assert_equal 302, last_response.status, last_response.body
    mos7 = Bingo::Datacenter[slug: 'ix-mos7']
    assert_equal 9, mos7.position
    assert_equal 10, @dcs[8].refresh.position          # old #9 shifted down
    assert_equal 26, @dcs[24].refresh.position         # old #25 now in reserve
    assert_equal (1..26).to_a, Bingo::Datacenter.order(:position).select_map(:position)

    board = Bingo::Board.load
    assert_equal 25, board.cells.size
    refute_includes board.cells.map(&:slug), 'dc-25'
    assert_includes board.cells.map(&:slug), 'ix-mos7'
  end

  def test_admin_rejects_bad_or_duplicate_slug
    token = admin_token('/admin/bingo/dc/new')
    post '/admin/bingo/dc', dc_params(authenticity_token: token, slug: 'Bad Slug'), admin_env
    assert_equal 422, last_response.status
    post '/admin/bingo/dc', dc_params(authenticity_token: token, slug: 'dc-1'), admin_env
    assert_equal 422, last_response.status
    assert_equal 25, Bingo::Datacenter.count
  end

  def test_admin_moves_datacenter
    token = admin_token("/admin/bingo/dc/#{@dcs[24].id}")
    post "/admin/bingo/dc/#{@dcs[24].id}", dc_params(authenticity_token: token, name_ru: 'ЦОД 25', position: '1'), admin_env
    assert_equal 1, @dcs[24].refresh.position
    assert_equal 2, @dcs[0].refresh.position
    assert_equal (1..25).to_a, Bingo::Datacenter.order(:position).select_map(:position)
  end

  def test_admin_deletes_datacenter_with_incidents
    hit!(4)
    token = admin_token("/admin/bingo/dc/#{@dcs[4].id}")
    post "/admin/bingo/dc/#{@dcs[4].id}/delete", { authenticity_token: token }, admin_env
    assert_equal 302, last_response.status
    assert_nil Bingo::Datacenter[@dcs[4].id]
    assert_equal 0, Bingo::Incident.count
    assert_equal (1..24).to_a, Bingo::Datacenter.order(:position).select_map(:position)
  end

  def test_sort_by_mw
    @dcs[0].update(mw: '')    # unknown → last
    @dcs[1].update(mw: '25–30')
    Bingo.sort_by_mw!
    order = Bingo::Datacenter.order(:position).select_map(:slug)
    assert_equal %w[dc-2 dc-25 dc-24], order.first(3) # "25–30" ranks as 30
    assert_equal 'dc-1', order.last
  end

  def test_upload_photo_via_admin
    get "/admin/bingo/dc/#{@dcs[0].id}", {}, admin_env
    token = last_response.body[/name="authenticity_token" value="([^"]+)"/, 1]
    file = Rack::Test::UploadedFile.new(StringIO.new(JPEG), 'image/jpeg', original_filename: 'a.jpg')
    post "/admin/bingo/dc/#{@dcs[0].id}/photo", { authenticity_token: token, photo: file }, admin_env
    assert_equal 302, last_response.status
    assert_match %r{\Abingo/dc-1-}, @dcs[0].refresh.photo_key
  end
end
