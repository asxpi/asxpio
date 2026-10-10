Sequel.migration do
  change do
    # true once bingo/<slug>-<hex>-og.jpg (1200x630 og:image crop) exists;
    # rows with only the webp variants fall back to -1200.webp
    add_column :bingo_datacenters, :photo_og, TrueClass, null: false, default: false
  end
end
