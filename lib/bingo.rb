require 'sequel'
require 'json'
require 'net/http'
require 'securerandom'
require 'open3'
require_relative 's3'

# Datacenter bingo: a 5x5 card of the largest Russian datacenters; a cell is
# crossed out once a publicly sourced incident is recorded for it.
module Bingo
  LOCALES = %w[ru en uk].freeze
  KINDS   = %w[strike fire outage flood cooling other].freeze
  ICONS   = { 'strike' => '💥', 'fire' => '🔥', 'outage' => '⚡', 'flood' => '💧', 'cooling' => '🌡️', 'other' => '⚠️' }.freeze
  SIZE    = 5
  STATUSES = %w[operational building planned].freeze
  MW_TYPES = %w[it connected total design mva].freeze

  # Providers (companies) for the per-provider cards: slug => name per locale.
  PROVIDERS = {
    'yandex' => %w[Яндекс Yandex Яндекс], 'ixcellerate' => %w[IXcellerate] * 3,
    'rtk' => %w[РТК-ЦОД RTK-DC РТК-ЦОД], 'atomdata' => ['Атомдата (Росатом)', 'Atomdata (Rosatom)', 'Атомдата (Росатом)'],
    'datapro' => %w[DataPro] * 3, 'selectel' => %w[Selectel] * 3, 'mws' => ['MWS / МТС', 'MWS / MTS', 'MWS / МТС'],
    'keypoint' => ['Key Point'] * 3, '3data' => %w[3data] * 3, 'sber' => %w[Сбер Sber Сбер],
    'megafon' => %w[МегаФон MegaFon МегаФон], 'datahouse' => %w[DataHouse] * 3, 'oxygen' => %w[OXYGEN] * 3,
    'linx' => %w[Linx] * 3, 'cloudx' => ['Cloud X'] * 3, 'nkgroup' => ['NK Group'] * 3, 'goznak' => %w[Гознак Goznak Гознак],
    'dataspace' => %w[DataSpace] * 3, 'cloudru' => %w[Cloud.ru] * 3, 'x5' => ['X5 Group'] * 3, 'krok' => %w[КРОК CROC КРОК],
    'stack' => ['Stack Group'] * 3, 'beeline' => %w[Билайн Beeline Білайн], 'vk' => %w[VK] * 3
  }.transform_values { |names| %w[ru en uk].zip(names).to_h }.freeze

  PROVIDER_GUESS = [
    [/\AЯндекс/i, 'yandex'], [/\AIXcellerate/i, 'ixcellerate'], [/\AРТК-ЦОД/i, 'rtk'], [/\A(Атомдата|Росатом)/i, 'atomdata'],
    [/\ADataPro/i, 'datapro'], [/\ASelectel/i, 'selectel'], [/\A(MWS|МТС)/i, 'mws'], [/\AKey Point/i, 'keypoint'],
    [/\A3data/i, '3data'], [/\AСбер/i, 'sber'], [/\AМегаФон/i, 'megafon'], [/\ADataHouse/i, 'datahouse'],
    [/\AOXYGEN/i, 'oxygen'], [/\ALinx/i, 'linx'], [/\ACloud X/i, 'cloudx'], [/\ANK Group/i, 'nkgroup'], [/\AГознак/i, 'goznak'],
    [/\ADataSpace/i, 'dataspace'], [/\ACloud\.ru/i, 'cloudru'], [/\AX5/i, 'x5'], [/\A(КРОК|CROC)/i, 'krok'],
    [/\AStack/i, 'stack'], [/\A(Билайн|Beeline|ВымпелКом)/i, 'beeline'], [/\A(VK|ВКонтакте|М100)/i, 'vk']
  ].freeze

  def self.provider_name(slug, locale) = PROVIDERS.dig(slug, locale) || slug
  def self.guess_provider(operator) = PROVIDER_GUESS.find { |re, _| operator.to_s.match?(re) }&.last

  # Every row, column and both diagonals, as 0-based cell indices.
  LINES = (
    (0...SIZE).map { |r| (0...SIZE).map { |c| r * SIZE + c } } +
    (0...SIZE).map { |c| (0...SIZE).map { |r| r * SIZE + c } } +
    [(0...SIZE).map { |i| i * SIZE + i }, (0...SIZE).map { |i| i * SIZE + SIZE - 1 - i }]
  ).freeze

  # UI strings (T) and the public views live in the datacenterbingo repo,
  # which reads these tables; keep PROVIDERS, Board and the models in step.

  # Localized column with fallback to ru.
  module Localized
    def l(field, locale)
      v = self[:"#{field}_#{locale}"].to_s.strip
      v.empty? ? self[:"#{field}_ru"] : v
    end
  end

  class Datacenter < Sequel::Model(:bingo_datacenters)
    include Localized
    one_to_many :incidents, class: 'Bingo::Incident', key: :datacenter_id, order: Sequel.desc(:occurred_on)

    def before_create
      self.created_at ||= Time.now.utc
      self.provider ||= Bingo.guess_provider(operator)
      super
    end

    def before_save
      self.updated_at = Time.now.utc
      super
    end

    def operational? = status == 'operational'
    def planned?     = status == 'planned'

    def building?
      status == 'building'
    end

    # width: a Photo::WIDTHS variant (falls back to the original until the
    # variants exist), nil for the original.
    def photo_file(width = nil)
      return unless photo_key
      key = width && photo_variants ? Photo.variant_key(photo_key, width) : photo_key
      key.delete_prefix(Photo::PREFIX)
    end

    # Paragraphs of the datacenter page's prose in exactly this locale.
    def about(locale)
      self[:"about_#{locale}"].to_s.strip.split(/\n\s*\n/).map(&:strip)
    end

    # 1200x630 JPEG for og:image (every preview client renders it); the
    # webp dialog variant until it exists.
    def og_file
      return photo_file(1200) unless photo_key && photo_og
      Photo.og_key(photo_key).delete_prefix(Photo::PREFIX)
    end
  end

  class Incident < Sequel::Model(:bingo_incidents)
    include Localized
    many_to_one :datacenter, class: 'Bingo::Datacenter'

    # A removed incident changes its datacenter's cell.
    def after_destroy
      super
      Datacenter.where(id: datacenter_id).update(updated_at: Time.now.utc)
    end

    def before_create
      self.created_at ||= Time.now.utc
      super
    end

    def before_save
      self.updated_at = Time.now.utc
      super
    end
  end

  # Board state for rendering: ordered cells, hits and completed lines.
  VIEWS = %w[operational all].freeze # first is the default (bare URL)

  # The card: the first SIZE*SIZE datacenters by position, optionally only
  # operational ones (same ranking, construction projects skipped).
  # The card is always 5×5: the first SIZE*SIZE datacenters by position,
  # optionally only operational ones and/or only the chosen providers. A
  # selection with fewer datacenters leaves the remaining cells empty.
  Board = Struct.new(:cells, :hit, :wins, :incidents, :updated_on, :view, :providers) do
    def self.load(view = 'all', providers: nil)
      scope = Datacenter.order(:position, :id)
      scope = scope.where(status: 'operational') if view == 'operational'
      scope = scope.where(provider: providers) if providers&.any?
      cells = scope.limit(SIZE * SIZE).eager(:incidents).all
      hit   = cells.map { |dc| dc.incidents.any? }
      wins  = LINES.select { |line| line.all? { |i| hit[i] } }
      incidents = cells.flat_map(&:incidents).sort_by { |i| [i.occurred_on, i.id] }.reverse
      updated = [Datacenter.max(:updated_at), Incident.max(:updated_at)].compact.max
      new(cells, hit, wins, incidents, updated, view, providers)
    end

    def filtered? = providers&.any? || false

    # [[slug, total, crossed]] for every provider with datacenters in this view.
    def self.providers(view)
      scope = Datacenter.exclude(provider: nil)
      scope = scope.where(status: 'operational') if view == 'operational'
      scope.eager(:incidents).all.group_by(&:provider)
           .map { |slug, dcs| [slug, dcs.size, dcs.count { |d| d.incidents.any? }] }
           .sort_by { |slug, n, x| [-x, -n, slug] }
    end

    def operational_only? = view == 'operational'

    def win_cells
      @win_cells ||= wins.flatten.to_set
    end
  end

  # Photos live under bingo/ in Photo.bucket and are proxied by the bingo
  # site (and /admin/bingo/p here), so the bucket stays private.
  module Photo
    PREFIX    = 'bingo/'.freeze
    MAX_BYTES = 8 * 1024 * 1024
    FILE_RE   = /\A[a-z0-9-]+-[0-9a-f]{8}(?:-(?:480|1200|og))?\.(jpg|png|webp)\z/
    WIDTHS    = [480, 1200].freeze # card cell (2x), dialog
    OG_SIZE   = [1200, 630].freeze # og:image, cropped to the 1.91:1 card
    CONVERT   = ENV.fetch('BINGO_CONVERT', 'convert') # ImageMagick
    TYPES     = { 'jpg' => 'image/jpeg', 'png' => 'image/png', 'webp' => 'image/webp' }.freeze

    class Error < StandardError; end

    module_function

    # Own bucket in prod (datacenterbingo-photos, shared read-only with the
    # bingo site); unset = the app bucket (dev, tests).
    def bucket = ENV['BINGO_S3_BUCKET'].to_s.empty? ? S3.bucket : ENV['BINGO_S3_BUCKET']

    # Input may arrive tagged UTF-8 (aws-sdk bodies are plain StringIOs), and
    # comparing that with binary literals raises, so look at raw bytes.
    def sniff(bytes)
      bytes = bytes.b
      return 'jpg'  if bytes.start_with?("\xFF\xD8\xFF".b)
      return 'png'  if bytes.start_with?("\x89PNG\r\n\x1A\n".b)
      return 'webp' if bytes[0, 4] == 'RIFF' && bytes[8, 4] == 'WEBP'
      nil
    end

    # Stores bytes and returns the new key; the old object is left in place
    # (cheap, and keeps cached URLs valid until their max-age runs out).
    def store(slug, bytes)
      bytes = bytes.b
      raise Error, 'image too large (max 8 MB)' if bytes.bytesize > MAX_BYTES
      ext = sniff(bytes) or raise Error, 'not a JPEG, PNG or WebP image'
      bytes = strip_metadata(bytes, ext)
      key = "#{PREFIX}#{slug}-#{SecureRandom.hex(4)}.#{ext}"
      S3.put(key, bytes, content_type: TYPES[ext], bucket: bucket)
      key
    end

    # Stores the photo for dc and makes it current. Variants are best effort:
    # without them the card falls back to the original.
    def attach(dc, bytes)
      key = store(dc.slug, bytes)
      dc.update(photo_key: key, **build_variants(key, bytes))
      key
    end

    # Re-derives the variants from the stored original.
    def rebuild(dc)
      dc.update(**build_variants(dc.photo_key, S3.get(dc.photo_key, bucket: bucket)))
    end

    def variant_key(key, width)
      key.sub(/\.\w+\z/, "-#{width}.webp")
    end

    def og_key(key)
      key.sub(/\.\w+\z/, '-og.jpg')
    end

    # Column values for the datacenter row: all variants or none.
    def build_variants(key, bytes)
      bytes = bytes.b
      ext = sniff(bytes) or raise Error, 'not an image'
      WIDTHS.each { |w| S3.put(variant_key(key, w), resize(bytes, ext, w), content_type: TYPES['webp'], bucket: bucket) }
      S3.put(og_key(key), og_crop(bytes, ext), content_type: TYPES['jpg'], bucket: bucket)
      { photo_variants: true, photo_og: true }
    rescue Error => e
      $logger.warn("bingo: no variants for #{key}: #{e.message}")
      { photo_variants: false, photo_og: false }
    end

    # Downscale (never up) to fit width x width, re-encode as WebP.
    def resize(bytes, ext, width)
      convert(bytes, ext, ['-resize', "#{width}x#{width}>", '-quality', '80'], 'webp')
    end

    # Fill OG_SIZE and crop the overflow around the centre.
    def og_crop(bytes, ext)
      w, h = OG_SIZE
      convert(bytes, ext, ['-resize', "#{w}x#{h}^", '-gravity', 'center', '-extent', "#{w}x#{h}",
                           '-quality', '82'], 'jpg')
    end

    # -strip drops metadata again. The input coder is pinned to the sniffed
    # type and memory/area limits guard against decompression bombs.
    def convert(bytes, ext, ops, out_ext)
      coder = { 'jpg' => 'jpeg', 'png' => 'png', 'webp' => 'webp' }
      out, err, st = Open3.capture3(
        CONVERT, '-limit', 'memory', '256MiB', '-limit', 'area', '128MP',
        "#{coder.fetch(ext)}:-", '-auto-orient', *ops, '-strip', "#{coder.fetch(out_ext)}:-",
        stdin_data: bytes, binmode: true
      )
      raise Error, "convert: #{err.lines.first&.strip}" unless st.success? && sniff(out.b) == out_ext
      out.b
    rescue Errno::ENOENT
      raise Error, 'ImageMagick (convert) not installed'
    rescue Errno::EPIPE, IOError => e # convert exited before reading all input
      raise Error, "convert: #{e.class}"
    end

    # Photos are served byte-for-byte, so drop EXIF/XMP/IPTC/text metadata:
    # phone shots carry GPS coordinates, and the card stays city-level.
    # Pixel data is untouched; malformed input is rejected rather than
    # passed through.
    def strip_metadata(bytes, ext)
      case ext
      when 'jpg'  then strip_jpeg(bytes)
      when 'png'  then strip_png(bytes)
      when 'webp' then strip_webp(bytes)
      end
    end

    JPEG_DROP = [0xE1, *0xE3..0xEF, 0xFE].freeze # APP1 (Exif/XMP), APP3-15 (IPTC...), COM

    def strip_jpeg(b)
      out = +"\xFF\xD8".b
      i = 2
      while i < b.bytesize
        raise Error, 'corrupt JPEG' unless b.getbyte(i) == 0xFF
        marker = b.getbyte(i + 1)
        if marker == 0xFF then i += 1; next end # fill byte
        if marker == 0xDA || marker == 0xD9     # start of scan: rest is image data
          return out << b.byteslice(i..)
        end
        len = b.byteslice(i + 2, 2)&.unpack1('n') or raise Error, 'corrupt JPEG'
        out << b.byteslice(i, len + 2) unless JPEG_DROP.include?(marker)
        i += len + 2
      end
      raise Error, 'corrupt JPEG'
    end

    PNG_DROP = %w[eXIf tEXt iTXt zTXt tIME].freeze

    def strip_png(b)
      out = b.byteslice(0, 8)
      i = 8
      while i + 8 <= b.bytesize
        len, type = b.byteslice(i, 8).unpack('Na4')
        out << b.byteslice(i, len + 12) unless PNG_DROP.include?(type)
        i += len + 12
        return out if type == 'IEND'
      end
      raise Error, 'corrupt PNG'
    end

    def strip_webp(b)
      body = +''.b
      i = 12
      while i + 8 <= b.bytesize
        type, len = b.byteslice(i, 8).unpack('a4V')
        chunk = b.byteslice(i, 8 + len + (len & 1))
        if type == 'VP8X'
          chunk = chunk.dup
          chunk.setbyte(8, chunk.getbyte(8) & ~0x0C) # clear EXIF + XMP flags
        end
        body << chunk unless %w[EXIF XMP\ ].include?(type)
        i += 8 + len + (len & 1)
      end
      raise Error, 'corrupt WebP' if body.empty?
      'RIFF'.b + [body.bytesize + 4].pack('V') + 'WEBP'.b + body
    end

    # Admin-only "import from URL". https only, a few redirects, size-capped.
    def fetch(url, redirects: 3)
      uri = URI(url)
      raise Error, 'https URL required' unless uri.is_a?(URI::HTTPS)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 15) do |http|
        req = Net::HTTP::Get.new(uri)
        # Wikimedia rate-limits generic agents; its policy wants name + contact.
        req['User-Agent'] = 'asxpio-bingo/1.0 (https://asxp.io; ie@asxp.io)'
        http.request(req) do |res|
          case res
          when Net::HTTPRedirection
            raise Error, 'too many redirects' if redirects.zero?
            return fetch(URI.join(uri, res['location']).to_s, redirects: redirects - 1)
          when Net::HTTPSuccess
            body = +''.b
            res.read_body do |chunk|
              body << chunk
              raise Error, 'image too large (max 8 MB)' if body.bytesize > MAX_BYTES
            end
            return body
          else
            raise Error, "HTTP #{res.code} from #{uri.host}"
          end
        end
      end
    rescue URI::InvalidURIError, SocketError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError, Errno::ECONNREFUSED => e
      raise Error, e.message
    end

    def read(file)
      raise Error, 'bad name' unless file =~ FILE_RE
      [S3.get(PREFIX + file, bucket: bucket), TYPES[Regexp.last_match(1)]]
    end
  end

  # Tells IndexNow engines (Bing, Yandex, Seznam, ...) which bingo URLs
  # changed, so new incidents get recrawled within minutes. The key comes
  # from INDEXNOW_KEY; the bingo site (datacenterbingo repo, same key)
  # serves it at /<key>.txt. Without the key
  # or BINGO_HOST (dev, tests) this does nothing.
  module IndexNow
    ENDPOINT = URI('https://api.indexnow.org/indexnow')

    module_function

    def key  = ENV['INDEXNOW_KEY'].to_s[/\A[A-Za-z0-9-]{8,128}\z/]
    def host = ENV['BINGO_HOST'].to_s[/\A\S+\z/]

    # The card in every locale plus the pages of the given datacenters.
    def urls(dcs = [])
      paths = LOCALES.map { |l| "/#{l}" } + dcs.flat_map { |dc| LOCALES.map { |l| "/#{l}/dc/#{dc.slug}" } }
      paths.map { |p| "https://#{host}#{p}" }
    end

    def payload(dcs = [])
      { host: host, key: key, keyLocation: "https://#{host}/#{key}.txt", urlList: urls(dcs) }
    end

    # Fire and forget: an admin save doesn't wait on a third party.
    def ping(dcs = [])
      return unless key && host
      body = JSON.generate(payload(dcs))
      Thread.new { deliver(body) }
    end

    def deliver(body)
      res = Net::HTTP.start(ENDPOINT.host, ENDPOINT.port, use_ssl: true, open_timeout: 5, read_timeout: 10) do |http|
        http.post(ENDPOINT.path, body, 'Content-Type' => 'application/json; charset=utf-8')
      end
      $logger.warn("bingo: IndexNow answered #{res.code}") unless res.is_a?(Net::HTTPSuccess)
    rescue StandardError => e
      $logger.warn("bingo: IndexNow #{e.class}: #{e.message}")
    end
  end

  # Positions stay dense 1..N; the card shows the first SIZE*SIZE, the rest
  # wait in reserve. Placing a datacenter inserts it at pos (default: last)
  # and shifts everyone after it.
  def self.place!(dc, pos = nil)
    DB.connection.transaction do
      ids = Datacenter.exclude(id: dc.id).order(:position, :id).select_map(:id)
      pos = (pos || ids.size + 1).clamp(1, ids.size + 1)
      renumber!(ids.insert(pos - 1, dc.id))
    end
  end

  def self.renumber!(ids = Datacenter.order(:position, :id).select_map(:id))
    now = Time.now.utc
    ids.each_with_index do |id, i|
      Datacenter.where(id: id).exclude(position: i + 1).update(position: i + 1, updated_at: now)
    end
  end

  # "64" → 64.0, "25–30" → 30.0, ">40" → 40.0, "13,7" → 13.7, "" → nil
  def self.mw_value(mw)
    mw.to_s.tr(',', '.').scan(/\d+(?:\.\d+)?/).map(&:to_f).max
  end

  # Rank by power, unknown last; ties keep their current order.
  def self.sort_by_mw!
    DB.connection.transaction do
      renumber!(Datacenter.order(:position, :id).all
                          .sort_by.with_index { |dc, i| [-(mw_value(dc.mw) || -1), i] }.map(&:id))
    end
  end

  # First boot: fill the card (and any already-known incidents) from
  # db/bingo_seed.json. Never touches rows once any exist; edits happen in
  # /admin/bingo.
  def self.seed!
    return if Datacenter.count.positive?
    path = File.join($root, 'db', 'bingo_seed.json')
    return unless File.exist?(path)
    seed = JSON.parse(File.read(path, encoding: 'UTF-8'))
    cols = Datacenter.columns.map(&:to_s) - %w[id created_at updated_at]
    DB.connection.transaction do
      ids = seed.fetch('datacenters').each_with_index.to_h do |row, i|
        dc = Datacenter.create(row.slice(*cols).merge('position' => row['position'] || i + 1))
        [dc.slug, dc.id]
      end
      seed.fetch('incidents', []).each do |row|
        Incident.create(row.slice(*(Incident.columns.map(&:to_s) - %w[id created_at updated_at datacenter_id]))
                           .merge('datacenter_id' => ids.fetch(row.fetch('slug'))))
      end
    end
  end
end
