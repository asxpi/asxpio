require 'sequel'
require_relative 'crypto_asset'

# Default payout address per coin (see migration 010).
class PayoutAddress < Sequel::Model(:payout_addresses)
  unrestrict_primary_key
  ADDRESS_RE = /\A[a-zA-Z0-9]{10,128}\z/ # same loose shape check as invoices

  def self.map
    to_hash(:coin, :address).slice(*CryptoAsset::CODES)
  end

  # First boot after the move: take over what the env/Forgejo secrets held.
  def self.seed_from_env!
    return if count.positive?
    CryptoAsset.env_addresses.each do |coin, address|
      next unless address.match?(ADDRESS_RE)
      create(coin: coin, address: address, updated_by: 'env import', updated_at: Time.now.utc)
    end
  end

  # Upsert or (blank address) delete. Returns an error string or nil.
  def self.set!(coin, address, by:)
    coin = coin.to_s.upcase
    return 'unknown coin' unless CryptoAsset.valid?(coin)
    address = address.to_s.strip
    if address.empty?
      where(coin: coin).delete
      return nil
    end
    return "#{coin}: address looks invalid" unless address.match?(ADDRESS_RE)
    row = self[coin] || new(coin: coin)
    row.set(address: address, updated_by: by, updated_at: Time.now.utc).save
    nil
  end
end
