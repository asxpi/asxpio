require 'sequel'
require 'json'
require 'net/http'
require 'securerandom'
require_relative 's3'

# Datacenter bingo: a 5x5 card of the largest Russian datacenters; a cell is
# crossed out once a publicly sourced incident is recorded for it.
module Bingo
  LOCALES = %w[ru en uk].freeze
  KINDS   = %w[strike fire outage flood cooling other].freeze
  ICONS   = { 'strike' => '💥', 'fire' => '🔥', 'outage' => '⚡', 'flood' => '💧', 'cooling' => '🌡️', 'other' => '⚠️' }.freeze
  SIZE    = 5

  # Every row, column and both diagonals, as 0-based cell indices.
  LINES = (
    (0...SIZE).map { |r| (0...SIZE).map { |c| r * SIZE + c } } +
    (0...SIZE).map { |c| (0...SIZE).map { |r| r * SIZE + c } } +
    [(0...SIZE).map { |i| i * SIZE + i }, (0...SIZE).map { |i| i * SIZE + SIZE - 1 - i }]
  ).freeze

  T = {
    'ru' => {
      title: 'Бинго ЦОДов', accent: 'ЦОДов', lead: 'Бинго',
      desc: 'Топ-25 дата-центров России по мощности. Клетка зачёркивается после публично подтверждённого инцидента.',
      crossed: 'Зачёркнуто', lines: 'линий', updated: 'обновлено',
      log: 'Журнал инцидентов', empty: 'Пока всё работает. Пока.',
      bingo: 'БИНГО!', bingo_n: 'БИНГО ×%d!', full: 'ПОЛНАЯ КАРТА. Интернета больше нет.',
      building: 'строится', mw: 'МВт', since: 'с %d г.', photo: 'Фото', source: 'Источник',
      close: 'Закрыть', no_incidents: 'Инцидентов не зафиксировано.',
      footer: 'Данные из открытых источников (2025–2026). Клетка зачёркивается только по публичному источнику.',
      kinds: { 'strike' => 'Атака БПЛА', 'fire' => 'Пожар', 'outage' => 'Отключение', 'flood' => 'Затопление', 'cooling' => 'Перегрев', 'other' => 'Инцидент' },
      letters: %w[Б И Н Г О]
    },
    'en' => {
      title: 'Datacenter Bingo', accent: 'Bingo', lead: 'Datacenter',
      desc: "Russia's 25 largest datacenters by power. A cell is crossed out after a publicly reported incident.",
      crossed: 'Crossed out', lines: 'lines', updated: 'updated',
      log: 'Incident log', empty: 'Everything is up. For now.',
      bingo: 'BINGO!', bingo_n: 'BINGO ×%d!', full: 'FULL CARD. There is no more internet.',
      building: 'under construction', mw: 'MW', since: 'since %d', photo: 'Photo', source: 'Source',
      close: 'Close', no_incidents: 'No incidents recorded.',
      footer: 'Open-source data (2025–2026). A cell is crossed out only with a public source.',
      kinds: { 'strike' => 'Drone strike', 'fire' => 'Fire', 'outage' => 'Outage', 'flood' => 'Flood', 'cooling' => 'Overheating', 'other' => 'Incident' },
      letters: %w[B I N G O]
    },
    'uk' => {
      title: 'Бінго ЦОДів', accent: 'ЦОДів', lead: 'Бінго',
      desc: 'Топ-25 дата-центрів Росії за потужністю. Клітинка закреслюється після публічно підтвердженого інциденту.',
      crossed: 'Закреслено', lines: 'ліній', updated: 'оновлено',
      log: 'Журнал інцидентів', empty: 'Поки що все працює. Поки що.',
      bingo: 'БІНГО!', bingo_n: 'БІНГО ×%d!', full: 'ПОВНА КАРТКА. Інтернету більше немає.',
      building: 'будується', mw: 'МВт', since: 'з %d р.', photo: 'Фото', source: 'Джерело',
      close: 'Закрити', no_incidents: 'Інцидентів не зафіксовано.',
      footer: 'Дані з відкритих джерел (2025–2026). Клітинка закреслюється лише за публічним джерелом.',
      kinds: { 'strike' => 'Атака БПЛА', 'fire' => 'Пожежа', 'outage' => 'Відключення', 'flood' => 'Затоплення', 'cooling' => 'Перегрів', 'other' => 'Інцидент' },
      letters: %w[Б І Н Г О]
    }
  }.freeze

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
      super
    end

    def building?
      status == 'building'
    end

    def photo_file
      photo_key&.delete_prefix(Photo::PREFIX)
    end
  end

  class Incident < Sequel::Model(:bingo_incidents)
    include Localized
    many_to_one :datacenter, class: 'Bingo::Datacenter'

    def before_create
      self.created_at ||= Time.now.utc
      super
    end
  end

  # Board state for rendering: ordered cells, hits and completed lines.
  Board = Struct.new(:cells, :hit, :wins, :incidents, :updated_on) do
    def self.load
      cells = Datacenter.order(:position, :id).limit(SIZE * SIZE).eager(:incidents).all
      hit   = cells.map { |dc| dc.incidents.any? }
      wins  = LINES.select { |line| line.all? { |i| hit[i] } }
      incidents = cells.flat_map(&:incidents).sort_by { |i| [i.occurred_on, i.id] }.reverse
      updated = [Datacenter.max(:created_at), Incident.max(:created_at)].compact.max
      new(cells, hit, wins, incidents, updated)
    end

    def win_cells
      @win_cells ||= wins.flatten.to_set
    end
  end

  # Photos live in the app's MinIO bucket under bingo/ and are proxied by the
  # app, so the bucket stays private.
  module Photo
    PREFIX    = 'bingo/'.freeze
    MAX_BYTES = 8 * 1024 * 1024
    FILE_RE   = /\A[a-z0-9-]+-[0-9a-f]{8}\.(jpg|png|webp)\z/
    TYPES     = { 'jpg' => 'image/jpeg', 'png' => 'image/png', 'webp' => 'image/webp' }.freeze

    class Error < StandardError; end

    module_function

    def sniff(bytes)
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
      S3.put(key, bytes, content_type: TYPES[ext])
      key
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
            body = +''
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
      [S3.get(PREFIX + file), TYPES[Regexp.last_match(1)]]
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
    ids.each_with_index { |id, i| Datacenter.where(id: id).update(position: i + 1) }
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
    cols = Datacenter.columns.map(&:to_s) - %w[id created_at]
    DB.connection.transaction do
      ids = seed.fetch('datacenters').each_with_index.to_h do |row, i|
        dc = Datacenter.create(row.slice(*cols).merge('position' => row['position'] || i + 1))
        [dc.slug, dc.id]
      end
      seed.fetch('incidents', []).each do |row|
        Incident.create(row.slice(*(Incident.columns.map(&:to_s) - %w[id created_at datacenter_id]))
                           .merge('datacenter_id' => ids.fetch(row.fetch('slug'))))
      end
    end
  end
end
