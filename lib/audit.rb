require 'sequel'

# Append-only record of who changed what in the admin (/admin/audit).
module Audit
  module_function

  def log(action:, user: nil, target: nil, detail: nil, ip: nil, username: nil)
    DB.connection[:audit_log].insert(
      user_id: user&.id, username: user&.username || username, action: action,
      target: target&.to_s&.slice(0, 200), detail: detail&.to_s&.slice(0, 2000),
      ip: ip, created_at: Time.now.utc
    )
  rescue Sequel::Error => e
    $logger.error("audit: #{action} not recorded: #{e.message}") # never break the action itself
  end

  def recent(limit = 200)
    DB.connection[:audit_log].order(Sequel.desc(:created_at), Sequel.desc(:id)).limit(limit).all
  end
end
