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
    # HSTS (1 year, this host only); http:// already 308s at the edge.
    set :protection, use: %i[strict_transport]
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

    def dc_path(dc, locale = @locale) = "/#{locale}/dc/#{dc.slug}"

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
      url = "#{base_url}#{dc_path(dc)}"
      place = { '@type' => 'Place', '@id' => "#{url}#place", 'url' => url, 'name' => dc.l(:name, @locale), 'address' => address }
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

    # Datacenter page: the Place plus a breadcrumb back to the card.
    def dc_json_ld(dc)
      JSON.generate(
        '@context' => 'https://schema.org',
        '@graph' => [
          ld_place(dc),
          { '@type' => 'BreadcrumbList', 'itemListElement' => [
            { '@type' => 'ListItem', 'position' => 1, 'name' => t(:title), 'item' => "#{base_url}/#{@locale}" },
            { '@type' => 'ListItem', 'position' => 2, 'name' => dc.l(:name, @locale), 'item' => "#{base_url}#{dc_path(dc)}" }
          ] }
        ]
      ).gsub('</', '<\/')
    end

    # Plain-language facts for the datacenter page and its meta description.
    def dc_facts(dc)
      [format(t(:dc_intro), name: dc.l(:name, @locale), city: dc.l(:city, @locale), operator: dc.operator),
       (format(t(:dc_capacity), mw: mw(dc)) if mw(dc)),
       { 'building' => t(:dc_building), 'planned' => t(:dc_planned) }[dc.status] || (dc.year && format(t(:dc_since), dc.year)),
       format(t(:dc_rank), pos: dc.position)].compact
    end

    def dc_latest(dc)
      i = dc.incidents.first or return t(:no_incidents)
      format(t(:dc_latest), date: fmt_date(i.occurred_on), title: i.l(:title, @locale))
    end

    # Cut at a word boundary to fit a search snippet.
    def snippet(text, max = 160)
      text.length <= max ? text : "#{text[0, max - 1][/\A.*(?=\s)/m] || text[0, max - 1]}…"
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

  # The card and every datacenter page (reserve included), each with its
  # language alternates.
  get '/sitemap.xml' do
    content_type 'application/xml'
    cache_control :public, max_age: 3600
    dcs = Bingo::Datacenter.order(:position, :id).eager(:incidents).all
    @entries = [[->(l) { "/#{l}" }, Bingo::Board.load.updated_on, '/']] +
               dcs.map { |dc| [->(l) { dc_path(dc, l) }, [dc.updated_at, *dc.incidents.map(&:updated_at)].compact.max] }
    erb :sitemap, layout: false
  end

  # One URL per page: /en/ is a duplicate of /en.
  get %r{/((?:ru|en|uk)(?:/dc/[a-z0-9-]+)?)/} do |path|
    qs = request.query_string
    redirect "/#{path}#{"?#{qs}" unless qs.empty?}", 301
  end

  get %r{/(ru|en|uk)} do |locale|
    @locale = locale
    @view   = Bingo::VIEWS.include?(params[:view]) ? params[:view] : 'all'
    @board  = Bingo::Board.load(@view)
    @title  = t(:seo_title)
    @desc   = format(t(:seo_desc), hit: @board.hit.count(true), total: @board.cells.size)
    @noindex = @board.operational_only?
    @path_for = ->(l) { "/#{l}" }
    @x_default = '/'
    @og = og_dc(@board)
    @ld = json_ld(@board, @desc)
    cache_control :public, max_age: 60
    erb :index
  end

  get %r{/(ru|en|uk)/dc/([a-z0-9-]+)} do |locale, slug|
    @locale = locale
    @dc = Bingo::Datacenter.where(slug: slug).eager(:incidents).first or halt 404
    @prev, @next = [-1, 1].map { |d| Bingo::Datacenter.first(position: @dc.position + d) }
    name, city = @dc.l(:name, locale), @dc.l(:city, locale)
    hit = @dc.incidents.first
    @title = hit ? format(t(:dc_title_hit), name: name, city: city, kind: kind_label(hit.kind), date: fmt_date(hit.occurred_on))
                 : format(t(:dc_title), name: name, city: city)
    @desc = snippet([*dc_facts(@dc).first(2), dc_latest(@dc)].join(' '))
    @path_for = ->(l) { dc_path(@dc, l) }
    @og = @dc if @dc.photo_key
    @ld = dc_json_ld(@dc)
    cache_control :public, max_age: 60
    erb :dc
  end

  # IndexNow key file: proves to the engines that pings come from us.
  get %r{/([A-Za-z0-9-]{8,128})\.txt} do |name|
    halt 404 unless name == Bingo::IndexNow.key
    content_type 'text/plain'
    name
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
