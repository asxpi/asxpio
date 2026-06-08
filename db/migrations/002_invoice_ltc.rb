Sequel.migration do
  change do
    alter_table(:invoices) do
      # LTC payout address captured at issue (defaults from LTC_ADDRESS env in the form).
      # All three are nullable: LTC payment is opt-in per invoice.
      add_column :ltc_address, String
      # LTC price in the invoice currency at issue time (snapshot, like gel_rate).
      # May be hand-entered or fetched from CoinGecko at form time.
      add_column :ltc_rate,    BigDecimal, size: [18, 8]
      # LTC amount due. Normally total / ltc_rate, but can be hand-overridden,
      # so it is stored explicitly rather than recomputed.
      add_column :ltc_amount,  BigDecimal, size: [18, 8]
    end
  end
end
