require 'sequel'
require 'openssl'
require 'securerandom'
require 'base64'
require 'rack/utils'
require 'uri'

# Admin accounts. Passwords are scrypt hashes from Ruby's OpenSSL (no gem):
# "scrypt$<logN>$<r>$<p>$<salt>$<hash>", base64 salt/hash.
class User < Sequel::Model(:users)
  AREAS    = %w[invoices bingo users].freeze
  PERMS    = %w[read write delete].freeze
  NAME_RE  = /\A[a-z0-9][a-z0-9_.@-]{1,63}\z/
  MIN_PASS = 12
  # 2^15 → 32 MiB, ~0.1 s per check; tests lower it via SCRYPT_LOG_N.
  SCRYPT   = { log_n: Integer(ENV.fetch('SCRYPT_LOG_N', '15')), r: 8, p: 1 }.freeze

  one_to_many :permissions, class: 'UserPermission', key: :user_id

  def self.hash_password(pass, log_n: SCRYPT[:log_n], r: SCRYPT[:r], p: SCRYPT[:p])
    salt = SecureRandom.random_bytes(16)
    dk   = OpenSSL::KDF.scrypt(pass.to_s, salt: salt, N: 2**log_n, r: r, p: p, length: 32)
    ['scrypt', log_n, r, p, Base64.strict_encode64(salt), Base64.strict_encode64(dk)].join('$')
  end

  def self.verify_password(pass, digest)
    algo, log_n, r, p, salt, hash = digest.to_s.split('$')
    return false unless algo == 'scrypt' && hash
    dk = OpenSSL::KDF.scrypt(pass.to_s, salt: Base64.strict_decode64(salt), N: 2**log_n.to_i,
                                        r: r.to_i, p: p.to_i, length: 32)
    Rack::Utils.secure_compare(Base64.strict_encode64(dk), hash)
  end

  # Same cost as a real check, so unknown usernames aren't faster to reject.
  DUMMY_DIGEST = hash_password(SecureRandom.hex(16))

  def self.authenticate(username, pass)
    user = self[username: username.to_s.strip.downcase]
    ok   = verify_password(pass, user&.password_digest || DUMMY_DIGEST)
    user if ok && user&.active && user.password_digest
  end

  def self.active_superuser?
    where(superuser: true, active: true).exclude(password_digest: nil).any?
  end

  # First boot: turn ADMIN_USER/ADMIN_PASSWORD into the first superuser.
  def self.bootstrap!(username, pass)
    return if count.positive? || username.to_s.strip.empty? || pass.to_s.empty?
    create(username: username.strip.downcase, superuser: true, password: pass)
    $logger.info("users: bootstrapped superuser #{username.strip.downcase}")
  end

  def before_create
    self.created_at ||= Time.now.utc
    super
  end

  def validate
    super
    errors.add(:username, 'lowercase letters, digits, . _ @ - (2–64)') unless username.to_s.match?(NAME_RE)
    errors.add(:email, 'invalid') if email && !email.match?(URI::MailTo::EMAIL_REGEXP)
  end

  def password=(pass)
    self.password_digest = self.class.hash_password(pass)
  end

  def authenticate(pass)
    password_digest && self.class.verify_password(pass, password_digest)
  end

  def can?(area, perm)
    return true if superuser
    row = permissions.find { |p| p.area == area.to_s }
    row ? row[:"can_#{perm}"] : false
  end

  def logout_everywhere!
    update(session_version: session_version + 1)
  end
end

class UserPermission < Sequel::Model(:user_permissions)
  unrestrict_primary_key
  many_to_one :user
end
