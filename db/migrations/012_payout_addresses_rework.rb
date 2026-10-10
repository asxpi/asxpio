require_relative '../../lib/crypto_asset'

Sequel.migration do
  up do
    # A payout address now carries everything an invoice needs: ticker
    # (coin), display name, QR URI scheme + amount parameter, CoinGecko id for
    # the live rate, the address, and an active flag. Several per ticker.
    alter_table(:payout_addresses) do
      drop_constraint :payout_addresses_pkey
      add_primary_key :id
      add_column :name, String
      add_column :scheme, String         # e.g. litecoin; NULL = bare address
      add_column :amount_param, String   # amount | tx_amount; NULL = none
      add_column :coingecko, String      # NULL = rate typed by hand
      add_column :active, TrueClass, null: false, default: true
    end

    # Invoices snapshot the payout metadata at issue (like the address), so
    # later edits never change an issued PDF or QR.
    alter_table(:invoices) do
      add_column :crypto_name, String
      add_column :crypto_scheme, String
      add_column :crypto_amount_param, String
    end

    CryptoAsset::DEFAULTS.each do |code, a|
      self[:payout_addresses].where(coin: code).update(name: a[:name], scheme: a[:scheme],
                                                       amount_param: a[:amount_param], coingecko: a[:coingecko])
      self[:invoices].where(crypto_coin: code).update(crypto_name: a[:name], crypto_scheme: a[:scheme],
                                                      crypto_amount_param: a[:amount_param])
    end
    self[:payout_addresses].where(name: nil).update(name: :coin)
  end

  down do
    alter_table(:invoices) do
      drop_column :crypto_amount_param
      drop_column :crypto_scheme
      drop_column :crypto_name
    end
    alter_table(:payout_addresses) do
      drop_column :active
      drop_column :coingecko
      drop_column :amount_param
      drop_column :scheme
      drop_column :name
      drop_column :id
      add_primary_key [:coin]
    end
  end
end
