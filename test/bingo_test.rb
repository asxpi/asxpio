require_relative 'test_helper'

class BingoTest < Minitest::Test
  include Rack::Test::Methods

  JPEG = "\xFF\xD8\xFF\xE0fakejpeg".b

  def app
    @app || BingoWeb
  end

  def setup
    skip 'TEST_DATABASE_URL not set' unless TestDb.available?
    DB.connection[:bingo_incidents].delete
    DB.connection[:bingo_datacenters].delete
    @dcs = (1..25).map do |n|
      Bingo::Datacenter.create(slug: "dc-#{n}", position: n, name_ru: "ЦОД #{n}", name_en: ("DC #{n}" if n == 1),
                               city_ru: 'Москва', city_en: 'Moscow', operator: 'Op', mw: n.to_s)
    end
  end

  def admin_env
    { 'HTTP_AUTHORIZATION' =>
        "Basic #{Base64.strict_encode64("#{ENV['ADMIN_USER']}:#{ENV['ADMIN_PASSWORD']}")}" }
  end

  def hit!(idx, kind: 'outage')
    Bingo::Incident.create(datacenter_id: @dcs[idx].id, occurred_on: Date.today, kind: kind,
                           title_ru: "Авария #{idx}", title_uk: "Аварія #{idx}")
  end

  def test_root_redirects_by_accept_language
    get '/', {}, 'HTTP_ACCEPT_LANGUAGE' => 'uk-UA,uk;q=0.9,en;q=0.8'
    assert_equal 302, last_response.status
    assert_match %r{/uk\z}, last_response.location
    get '/', {}, 'HTTP_ACCEPT_LANGUAGE' => 'de-DE'
    assert_match %r{/en\z}, last_response.location
  end

  def test_locales_render_with_ru_fallback
    get '/en'
    assert last_response.ok?
    assert_includes last_response.body, 'DC 1'     # localized
    assert_includes last_response.body, 'ЦОД 2'    # falls back to ru
    assert_includes last_response.body, 'Moscow'
    get '/uk'
    assert_includes last_response.body, 'Бінго'
    get '/xx'
    assert_equal 404, last_response.status
  end

  def test_board_detects_lines
    (0..4).each { |i| hit!(i) }     # top row
    [6, 12, 18, 24].each { |i| hit!(i) } # + main diagonal (0 already hit)
    board = Bingo::Board.load
    assert_equal 2, board.wins.size
    get '/ru'
    assert_includes last_response.body, 'БИНГО ×2!'
    assert_includes last_response.body, 'Авария 24'
    get '/uk'
    assert_includes last_response.body, 'Аварія 24'
  end

  def test_no_banner_without_line
    hit!(0)
    get '/ru'
    refute_includes last_response.body, 'class="banner"'
    assert_includes last_response.body, 'Авария 0'
  end

  def test_photo_store_and_serve
    Aws.config[:s3] = { stub_responses: { get_object: { body: JPEG } } }
    S3.instance_variable_set(:@client, nil)
    key = Bingo::Photo.store('dc-1', JPEG)
    assert_match %r{\Abingo/dc-1-[0-9a-f]{8}\.jpg\z}, key
    @dcs[0].update(photo_key: key)
    get "/p/#{@dcs[0].photo_file}"
    assert last_response.ok?
    assert_equal 'image/jpeg', last_response.content_type
    get '/p/..%2Finvoices%2Fx.pdf'
    assert_equal 404, last_response.status
  ensure
    Aws.config[:s3] = { stub_responses: true }
    S3.instance_variable_set(:@client, nil)
  end

  def test_photo_rejects_non_images
    assert_raises(Bingo::Photo::Error) { Bingo::Photo.store('dc-1', '<html>') }
  end

  # --- admin (served by AsxpioWeb) -------------------------------------------

  def test_admin_requires_auth
    @app = AsxpioWeb
    get '/admin/bingo'
    assert_equal 401, last_response.status
  end

  def test_admin_records_and_deletes_incident
    @app = AsxpioWeb
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
    @app = AsxpioWeb
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

  def test_upload_photo_via_admin
    @app = AsxpioWeb
    get "/admin/bingo/dc/#{@dcs[0].id}", {}, admin_env
    token = last_response.body[/name="authenticity_token" value="([^"]+)"/, 1]
    file = Rack::Test::UploadedFile.new(StringIO.new(JPEG), 'image/jpeg', original_filename: 'a.jpg')
    post "/admin/bingo/dc/#{@dcs[0].id}/photo", { authenticity_token: token, photo: file }, admin_env
    assert_equal 302, last_response.status
    assert_match %r{\Abingo/dc-1-}, @dcs[0].refresh.photo_key
  end
end
