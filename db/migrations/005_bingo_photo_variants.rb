Sequel.migration do
  change do
    # true once bingo/<slug>-<hex>-{480,1200}.webp exist next to the original
    add_column :bingo_datacenters, :photo_variants, TrueClass, null: false, default: false
  end
end
