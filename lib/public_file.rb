require 'digest'
require 'securerandom'
require 'sequel'
require_relative 's3'
require_relative 'bingo'

# A file published from /admin/files: an object in the public bucket, which
# anyone can fetch at #url, plus this row. The app's key can only put and
# delete there, so the row is the only way to find the object again.
class PublicFile < Sequel::Model(:public_files)
  class Error < StandardError; end

  # Types a browser may render in place. The bucket's host is same-site with
  # the admin, so anything that can carry script (HTML, SVG, XML, JS) is
  # stored as a generic download instead.
  INLINE = {
    'jpg' => 'image/jpeg', 'jpeg' => 'image/jpeg', 'png' => 'image/png', 'gif' => 'image/gif',
    'webp' => 'image/webp', 'avif' => 'image/avif', 'pdf' => 'application/pdf',
    'txt' => 'text/plain; charset=utf-8', 'md' => 'text/plain; charset=utf-8',
    'log' => 'text/plain; charset=utf-8', 'csv' => 'text/plain; charset=utf-8',
    'json' => 'text/plain; charset=utf-8', 'asc' => 'text/plain; charset=utf-8',
    'mp3' => 'audio/mpeg', 'ogg' => 'audio/ogg', 'wav' => 'audio/wav',
    'mp4' => 'video/mp4', 'webm' => 'video/webm'
  }.freeze
  DOWNLOAD = 'application/octet-stream'.freeze
  CACHE    = 'public, max-age=300'.freeze # short: a replaced file keeps its URL

  class << self
    # Own bucket in prod; unset = the app bucket (dev, tests).
    def bucket = ENV['PUBLIC_S3_BUCKET'].to_s.empty? ? S3.bucket : ENV['PUBLIC_S3_BUCKET']

    def base_url
      (ENV['PUBLIC_BASE_URL'] || "#{ENV['S3_PUBLIC_ENDPOINT']}/#{bucket}").chomp('/')
    end

    def max_bytes   = ENV.fetch('PUBLIC_MAX_MB', '50').to_i * 1024 * 1024
    def quota_bytes = ENV.fetch('PUBLIC_QUOTA_MB', '2048').to_i * 1024 * 1024
    def used_bytes  = sum(:size).to_i

    # ASCII only, so the key needs no escaping in the URL.
    def clean_name(name)
      name = File.basename(name.to_s.dup.force_encoding('UTF-8').scrub('-').tr('\\', '/'))
      tidy = ->(part) { part.gsub(/[^A-Za-z0-9._-]+/, '-').gsub(/-{2,}/, '-').gsub(/\A[-.]+|[-.]+\z/, '') }
      ext  = tidy.(File.extname(name).downcase)
      base = tidy.(File.basename(name, '.*'))[0, 80]
      "#{base.empty? ? 'file' : base}#{".#{ext}" unless ext.empty?}"
    end

    def ext_of(name) = File.extname(name).delete_prefix('.').downcase

    def publish(name, bytes, by:, note: nil, strip: true)
      filename = clean_name(name)
      file = new(filename: filename, key: "#{SecureRandom.hex(4)}/#{filename}", note: note,
                 created_at: Time.now.utc)
      file.store!(bytes, by: by, strip: strip)
    end
  end

  def url = "#{self.class.base_url}/#{key}"

  # Uploads bytes under this row's key and saves the row. Used for a new
  # file and for replacing the contents of an existing one.
  def store!(bytes, by:, strip: true)
    bytes = bytes.b
    raise Error, "#{filename}: empty file" if bytes.empty?
    raise Error, "#{filename}: larger than #{self.class.max_bytes / 1024 / 1024} MB" if bytes.bytesize > self.class.max_bytes
    bytes = strip_image(bytes) if strip
    others = self.class.exclude(id: id).sum(:size).to_i
    raise Error, "#{filename}: the public bucket quota is used up" if others + bytes.bytesize > self.class.quota_bytes

    type = INLINE[self.class.ext_of(filename)]
    S3.put(key, bytes, bucket: self.class.bucket, content_type: type || DOWNLOAD, cache_control: CACHE,
           content_disposition: type ? 'inline' : %(attachment; filename="#{filename}"))
    set(content_type: type || DOWNLOAD, inline: !type.nil?, size: bytes.bytesize,
        sha256: Digest::SHA256.hexdigest(bytes), uploaded_by: by, updated_at: Time.now.utc)
    save
  end

  def remove!
    S3.delete(key, bucket: self.class.bucket)
    destroy
  end

  private

  # Drops Exif and friends (GPS!) from JPEG, PNG and WebP; other types pass.
  def strip_image(bytes)
    kind = Bingo::Photo.sniff(bytes) or return bytes
    Bingo::Photo.strip_metadata(bytes, kind).b
  rescue Bingo::Photo::Error, ArgumentError, RangeError, NoMethodError
    raise Error, "#{filename}: could not strip the image metadata"
  end
end
