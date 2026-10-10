require 'uri'

# /admin/bingo/* on asxp.io: edit the card and record incidents for BingoWeb.
# Registered into AsxpioWeb, so AdminAuth (HTTP Basic) and CSRF apply.
module BingoAdmin
  DC_TEXT = %w[name_ru name_en name_uk city_ru city_en city_uk operator mw mw_type status
               photo_credit photo_source_url info_url].freeze

  module Helpers
    def bingo_public_url
      ENV['BINGO_HOST'] && "https://#{ENV['BINGO_HOST']}/ru"
    end

    def http_url?(s)
      s.empty? || s.match?(URI::DEFAULT_PARSER.make_regexp(%w[http https]))
    end

    def position_param
      params[:position].to_s =~ /\A\d+\z/ ? params[:position].to_i : nil
    end

    # Copies the edit form onto dc (position is handled by Bingo.place!).
    def assign_dc(dc)
      DC_TEXT.each { |f| dc[f.to_sym] = blank_nil(params[f]) }
      dc.year   = params[:year].to_s =~ /\A\d{4}\z/ ? params[:year].to_i : nil
      dc.status  = 'operational' unless Bingo::STATUSES.include?(dc.status)
      dc.mw_type = nil unless Bingo::MW_TYPES.include?(dc.mw_type)
      errs = []
      errs << 'Name (ru), city (ru) and operator are required' if [dc.name_ru, dc.city_ru, dc.operator].any?(&:nil?)
      errs << 'URLs must be http(s)' unless [dc.photo_source_url, dc.info_url].all? { |u| http_url?(u.to_s) }
      errs
    end

    def blank_nil(s)
      s = s.to_s.strip
      s.empty? ? nil : s
    end
  end

  def self.registered(app)
    app.helpers Helpers

    app.get '/admin/bingo' do
      @page_title = 'Bingo · admin'
      @noindex    = true
      @dcs        = Bingo::Datacenter.order(:position, :id).eager(:incidents).all
      @incidents  = Bingo::Incident.order(Sequel.desc(:occurred_on), Sequel.desc(:id)).eager(:datacenter).all
      @flash      = session.delete(:bingo_flash)
      erb :'admin/bingo/index'
    end

    app.get '/admin/bingo/dc/new' do
      @dc = Bingo::Datacenter.new(status: 'operational')
      @page_title = 'New datacenter · bingo admin'
      @noindex    = true
      erb :'admin/bingo/edit'
    end

    app.post '/admin/bingo/dc' do
      @dc = Bingo::Datacenter.new
      @dc.slug = params[:slug].to_s.strip.downcase
      errs = assign_dc(@dc)
      errs.unshift('Slug: lowercase letters, digits and dashes') unless @dc.slug.match?(/\A[a-z0-9]+(-[a-z0-9]+)*\z/)
      errs.unshift('Slug already taken') if Bingo::Datacenter.where(slug: @dc.slug).any?
      if errs.any?
        @flash = errs.join('; ')
        @page_title = 'New datacenter · bingo admin'
        @noindex    = true
        status 422
        return erb :'admin/bingo/edit'
      end
      @dc.position = Bingo::Datacenter.count + 1
      @dc.save
      Bingo.place!(@dc, position_param)
      audit!('bingo.dc_create', @dc.slug, "##{@dc.refresh.position} #{@dc.name_ru}")
      session[:bingo_flash] = "Added #{@dc.name_ru} at ##{@dc.refresh.position}."
      redirect "/admin/bingo/dc/#{@dc.id}"
    end

    app.get '/admin/bingo/dc/:id' do
      @dc = Bingo::Datacenter[params[:id].to_i] or halt 404
      @page_title = "#{@dc.name_ru} · bingo admin"
      @noindex    = true
      @flash      = session.delete(:bingo_flash)
      erb :'admin/bingo/edit'
    end

    app.post '/admin/bingo/dc/:id' do
      dc = Bingo::Datacenter[params[:id].to_i] or halt 404
      errs = assign_dc(dc)
      if errs.empty?
        dc.save_changes
        Bingo.place!(dc, position_param) if position_param && position_param != dc.position
        audit!('bingo.dc_update', dc.slug, dc.name_ru)
        session[:bingo_flash] = 'Saved.'
      else
        session[:bingo_flash] = errs.join('; ')
      end
      redirect "/admin/bingo/dc/#{dc.id}"
    end

    # Deletes the row and (FK cascade) its incidents; the photo object stays
    # in the bucket.
    app.post '/admin/bingo/dc/:id/delete' do
      dc = Bingo::Datacenter[params[:id].to_i] or halt 404
      n  = dc.incidents.size
      DB.connection.transaction do
        dc.destroy
        Bingo.renumber!
      end
      audit!('bingo.dc_delete', dc.slug, "#{dc.name_ru}, #{n} incident(s)")
      session[:bingo_flash] = "Deleted #{dc.name_ru}#{" and #{n} incident(s)" if n.positive?}."
      redirect '/admin/bingo'
    end

    app.post '/admin/bingo/sort' do
      Bingo.sort_by_mw!
      audit!('bingo.sort_by_mw')
      session[:bingo_flash] = 'Sorted by MW (unknown last).'
      redirect '/admin/bingo'
    end

    # Either an uploaded file or "import from URL" (defaults to photo_source_url).
    app.post '/admin/bingo/dc/:id/photo' do
      dc = Bingo::Datacenter[params[:id].to_i] or halt 404
      begin
        bytes =
          if params[:photo].is_a?(Hash) && params[:photo][:tempfile]
            params[:photo][:tempfile].read(Bingo::Photo::MAX_BYTES + 1)
          else
            url = blank_nil(params[:url]) || dc.photo_source_url or raise Bingo::Photo::Error, 'no file and no URL'
            dc.photo_source_url = url
            Bingo::Photo.fetch(url)
          end
        dc.save_changes
        Bingo::Photo.attach(dc, bytes)
        audit!('bingo.photo_store', dc.slug, dc.photo_source_url)
        session[:bingo_flash] = dc.photo_variants ? 'Photo stored.' : 'Photo stored (no resized variants; check logs).'
      rescue Bingo::Photo::Error => e
        session[:bingo_flash] = "Photo failed: #{e.message}"
      end
      redirect "/admin/bingo/dc/#{dc.id}"
    end

    app.post '/admin/bingo/dc/:id/photo/delete' do
      dc = Bingo::Datacenter[params[:id].to_i] or halt 404
      dc.update(photo_key: nil, photo_variants: false, photo_og: false)
      audit!('bingo.photo_remove', dc.slug)
      session[:bingo_flash] = 'Photo removed from card (object kept in bucket).'
      redirect "/admin/bingo/dc/#{dc.id}"
    end

    # Bulk: import every missing photo from its photo_source_url, or with
    # all=1 re-import every photo that has a source URL.
    app.post '/admin/bingo/photos/import' do
      ok, failed = 0, []
      scope = Bingo::Datacenter.exclude(photo_source_url: nil)
      scope = scope.where(photo_key: nil) unless params[:all] == '1'
      scope.each do |dc|
        Bingo::Photo.attach(dc, Bingo::Photo.fetch(dc.photo_source_url))
        ok += 1
      rescue Bingo::Photo::Error => e
        failed << "#{dc.slug}: #{e.message}"
      end
      audit!('bingo.photos_import', params[:all] == '1' ? 'all' : 'missing', "#{ok} ok, #{failed.size} failed")
      session[:bingo_flash] = (["Imported #{ok}."] + failed).join(' | ')
      redirect '/admin/bingo'
    end

    # Regenerate resized variants from the originals already in the bucket.
    app.post '/admin/bingo/photos/rebuild' do
      dcs = Bingo::Datacenter.exclude(photo_key: nil).all
      errors = {}
      dcs.each do |dc|
        Bingo::Photo.rebuild(dc)
      rescue StandardError => e # one bad object must not abort the batch
        errors[dc.slug] = "#{e.class}: #{e.message.lines.first&.strip}"
        $logger.error("bingo: rebuild #{dc.slug}: #{e.class}: #{e.message}")
      end
      failed = dcs.reject(&:photo_variants).map { |dc| errors[dc.slug] ? "#{dc.slug} (#{errors[dc.slug]})" : dc.slug }
      audit!('bingo.photos_rebuild', nil, "#{dcs.size - failed.size}/#{dcs.size}")
      session[:bingo_flash] = "Rebuilt #{dcs.size - failed.size}/#{dcs.size}.#{" Failed: #{failed.join(', ')}" if failed.any?}"
      redirect '/admin/bingo'
    end

    app.get '/admin/bingo/p/:file' do
      bytes, type = Bingo::Photo.read(params[:file])
      content_type type
      bytes
    rescue Bingo::Photo::Error, Aws::S3::Errors::NoSuchKey, Aws::S3::Errors::NotFound
      halt 404
    end

    app.post '/admin/bingo/incidents' do
      dc   = Bingo::Datacenter[params[:datacenter_id].to_i]
      date = begin
        Date.iso8601(params[:occurred_on].to_s)
      rescue Date::Error
        nil
      end
      url = params[:url].to_s.strip
      errs = []
      errs << 'Pick a datacenter'          unless dc
      errs << 'Valid date required'        unless date
      errs << 'Unknown kind'               unless Bingo::KINDS.include?(params[:kind])
      errs << 'Title (ru) required'        if params[:title_ru].to_s.strip.empty?
      errs << 'Source URL must be http(s)' unless http_url?(url)
      if errs.empty?
        Bingo::Incident.create(
          datacenter_id: dc.id, occurred_on: date, kind: params[:kind],
          title_ru: params[:title_ru].strip, title_en: blank_nil(params[:title_en]),
          title_uk: blank_nil(params[:title_uk]), url: blank_nil(url)
        )
        audit!('bingo.incident_create', dc.slug, "#{date} #{params[:kind]}: #{params[:title_ru].strip}")
        session[:bingo_flash] = "Incident recorded for #{dc.name_ru}."
      else
        session[:bingo_flash] = errs.join('; ')
      end
      redirect '/admin/bingo'
    end

    app.post '/admin/bingo/incidents/:id/delete' do
      inc = Bingo::Incident[params[:id].to_i]
      inc&.destroy # hook bumps the datacenter's updated_at
      audit!('bingo.incident_delete', inc&.datacenter&.slug, inc && "#{inc.occurred_on} #{inc.title_ru}")
      session[:bingo_flash] = 'Incident deleted.'
      redirect '/admin/bingo'
    end
  end
end
