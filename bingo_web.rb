# Public datacenter bingo, served on BINGO_HOST from the same process as
# AsxpioWeb (config.ru dispatches by Host). Read-only: no session, no CSRF.
# Content is managed from asxp.io/admin/bingo (lib/bingo_admin.rb).
class BingoWeb < Sinatra::Base
  configure do
    set :root, $root
    set :views, File.join($root, 'views', 'bingo')
    set :erb, layout: :layout, escape_html: true
    set :show_exceptions, $env == 'development'
    set :host_authorization,
        { permitted_hosts: $env == 'production' && ENV['BINGO_HOST'] ? [ENV['BINGO_HOST']] : [] }
  end

  helpers do
    def t(key) = Bingo::T[@locale][key]
    def kind_label(kind) = Bingo::T[@locale][:kinds][kind] || Bingo::T[@locale][:kinds]['other']
    def kind_icon(kind) = Bingo::ICONS[kind] || Bingo::ICONS['other']
    def photo_path(dc) = dc.photo_file && "/p/#{dc.photo_file}"
    def fmt_date(d) = d.strftime('%d.%m.%Y')

    def mw(dc)
      dc.mw.to_s.strip.empty? ? nil : "#{dc.mw} #{t(:mw)}"
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
    redirect "/#{preferred_locale}", 302
  end

  get %r{/(ru|en|uk)/?} do |locale|
    @locale = locale
    @board  = Bingo::Board.load
    cache_control :public, max_age: 60
    erb :index
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
