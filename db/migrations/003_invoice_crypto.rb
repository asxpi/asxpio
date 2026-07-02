Sequel.migration do
  up do
    alter_table(:invoices) do
      # Generalize the Litecoin-only columns: one crypto asset per invoice,
      # identified by crypto_coin (a CryptoAsset code, e.g. 'BTC', 'USDT-TRC20').
      rename_column :ltc_address, :crypto_address
      rename_column :ltc_rate,    :crypto_rate
      rename_column :ltc_amount,  :crypto_amount
      add_column :crypto_coin, String
    end
    run "UPDATE invoices SET crypto_coin = 'LTC' WHERE crypto_address IS NOT NULL"
  end

  down do
    alter_table(:invoices) do
      drop_column :crypto_coin
      rename_column :crypto_address, :ltc_address
      rename_column :crypto_rate,    :ltc_rate
      rename_column :crypto_amount,  :ltc_amount
    end
  end
end
