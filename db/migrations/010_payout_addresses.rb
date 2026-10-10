Sequel.migration do
  change do
    # Default crypto payout address per CryptoAsset code, prefilled into the
    # new-invoice form. Seeded once from the old CRYPTO_ADDRESSES/LTC_ADDRESS
    # env; managed at /admin/invoices/payout-addresses since.
    create_table(:payout_addresses) do
      String   :coin,    primary_key: true
      String   :address, null: false
      String   :updated_by
      DateTime :updated_at, null: false
    end
  end
end
