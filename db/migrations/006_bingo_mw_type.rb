Sequel.migration do
  change do
    # What the mw figure measures: it | connected | total | design | mva.
    # NULL = not stated by the source.
    add_column :bingo_datacenters, :mw_type, String
  end
end
