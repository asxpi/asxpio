# Public datacenter bingo, served on BINGO_HOST from the same process as
# AsxpioWeb (config.ru dispatches by Host). Read-only: no session, no CSRF.
# Content is managed from asxp.io/admin/bingo (lib/bingo_admin.rb).
class BingoWeb < Sinatra::Base
  HOSTS = [ENV['BINGO_HOST'], ENV['BINGO_ALT_HOST']].compact.reject(&:empty?).freeze

  configure do
    set :root, $root
    set :views, File.join($root, 'views', 'bingo')
    set :erb, layout: :layout, escape_html: true
    # public/ belongs to asxp.io (its robots.txt, sitemap, keys, admin JS);
    # the card needs none of it.
    set :static, false
    set :show_exceptions, $env == 'development'
    set :host_authorization,
        { permitted_hosts: $env == 'production' ? HOSTS : [] }
  end

  helpers do
    def t(key) = Bingo::T[@locale][key]
    def kind_label(kind) = Bingo::T[@locale][:kinds][kind] || Bingo::T[@locale][:kinds]['other']
    def kind_icon(kind) = Bingo::ICONS[kind] || Bingo::ICONS['other']
    def photo_path(dc, width = nil) = dc.photo_file(width) && "/p/#{dc.photo_file(width)}"
    # Path for a locale/view combination; the default view keeps a bare URL.
    def card_path(locale = @locale, view = @view)
      view == 'operational' ? "/#{locale}?view=operational" : "/#{locale}"
    end

    def base_url = "https://#{ENV.fetch('BINGO_HOST', request.host)}"

    # WebSite + ItemList of the card's datacenters, for rich results.
    def json_ld(board, desc)
      url = "#{base_url}/#{@locale}"
      JSON.generate(
        '@context' => 'https://schema.org',
        '@graph' => [
          { '@type' => 'WebSite', '@id' => "#{base_url}/#website", 'url' => "#{base_url}/",
            'name' => t(:title), 'inLanguage' => Bingo::LOCALES,
            'publisher' => { '@type' => 'Person', 'name' => 'asxpi', 'url' => 'https://asxp.io' } },
          { '@type' => 'ItemList', 'url' => url, 'name' => t(:seo_title), 'description' => desc,
            'inLanguage' => @locale, 'numberOfItems' => board.cells.size,
            'dateModified' => board.updated_on&.utc&.iso8601,
            'itemListElement' => board.cells.each_with_index.map do |dc, i|
              { '@type' => 'ListItem', 'position' => i + 1, 'item' => ld_place(dc) }
            end }.compact
        ]
      ).gsub('</', '<\/')
    end

    # The info_url describes the datacenter (operator page, news), it isn't
    # the datacenter's own identity, so subjectOf rather than sameAs.
    # Incidents are Events at the place.
    def ld_place(dc)
      address = { '@type' => 'PostalAddress', 'addressLocality' => dc.l(:city, @locale), 'addressCountry' => 'RU' }
      place = { '@type' => 'Place', 'name' => dc.l(:name, @locale), 'address' => address }
      place['image'] = "#{base_url}#{photo_path(dc, 1200)}" if dc.photo_key
      place['subjectOf'] = { '@type' => 'CreativeWork', 'url' => dc.info_url } if dc.info_url
      events = dc.incidents.map do |i|
        { '@type' => 'Event', 'name' => "#{kind_label(i.kind)}: #{i.l(:title, @locale)}",
          'startDate' => i.occurred_on.iso8601, 'url' => i.url,
          'location' => { '@type' => 'Place', 'name' => place['name'], 'address' => address } }.compact
      end
      place['event'] = events if events.any?
      place
    end

    # Preview image: the most recent hit with a photo, else the first photo.
    def og_dc(board)
      board.incidents.map(&:datacenter).find(&:photo_key) || board.cells.find(&:photo_key)
    end
    def fmt_date(d) = d.strftime('%d.%m.%Y')

    # "64 MW", "64 MW · design", "17 MVA" (MVA is a unit, not a tag).
    def mw(dc, tag: true)
      return if dc.mw.to_s.strip.empty?
      return "#{dc.mw} #{t(:mva)}" if dc.mw_type == 'mva'
      tag &&= t(:mw_types)[dc.mw_type]
      ["#{dc.mw} #{t(:mw)}", tag || nil].compact.join(' · ')
    end

    # Badge for anything not yet in service.
    def status_label(dc)
      { 'building' => t(:building), 'planned' => t(:planned) }[dc.status]
    end

    def preferred_locale
      langs = request.env['HTTP_ACCEPT_LANGUAGE'].to_s.downcase.scan(/([a-z]{2})(?:-[a-z]+)?(?:;q=([\d.]+))?/)
      langs.sort_by { |_, q| -(q || '1').to_f }.map(&:first).find { |l| Bingo::LOCALES.include?(l) } || 'en'
    end
  end

  before do
    halt 503, 'Bingo not configured (DATABASE_URL missing).' unless defined?(Bingo::Datacenter)
  end

  get '/' do
    headers 'Vary' => 'Accept-Language'
    redirect "/#{preferred_locale}", 302
  end

  get '/robots.txt' do
    content_type 'text/plain'
    "User-agent: *\nAllow: /\n\nSitemap: #{base_url}/sitemap.xml\n"
  end

  get '/sitemap.xml' do
    content_type 'application/xml'
    cache_control :public, max_age: 3600
    @lastmod = Bingo::Board.load.updated_on
    erb :sitemap, layout: false
  end

  # One URL per page: /en/ is a duplicate of /en.
  get %r{/(ru|en|uk)/} do |locale|
    qs = request.query_string
    redirect "/#{locale}#{"?#{qs}" unless qs.empty?}", 301
  end

  get %r{/(ru|en|uk)} do |locale|
    @locale = locale
    @view   = Bingo::VIEWS.include?(params[:view]) ? params[:view] : 'all'
    @board  = Bingo::Board.load(@view)
    cache_control :public, max_age: 60
    erb :index
  end

  # Icons from assets/bingo/ (public/ is asxp.io's). Search engines want
  # a crawlable favicon URL; a data: URI doesn't count.
  ICONS = { 'favicon.svg' => 'image/svg+xml', 'favicon.ico' => 'image/x-icon',
            'apple-touch-icon.png' => 'image/png' }.freeze

  get %r{/(favicon\.svg|favicon\.ico|apple-touch-icon\.png)} do |name|
    cache_control :public, max_age: 86_400
    send_file File.join(settings.root, 'assets', 'bingo', name), type: ICONS[name]
  end

  # Photos are immutable per key (a new upload gets a new key).
  get '/p/:file' do
    bytes, type = Bingo::Photo.read(params[:file])
    content_type type
    cache_control :public, :immutable, max_age: 31_536_000
    bytes
  rescue Bingo::Photo::Error, Aws::S3::Errors::NoSuchKey, Aws::S3::Errors::NotFound
    halt 404
  end

  not_found do
    'Not found'
  end
end
