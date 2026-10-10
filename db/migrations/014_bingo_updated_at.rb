Sequel.migration do
  up do
    # Last change to the row, for the "updated" date and sitemap lastmod.
    %i[bingo_datacenters bingo_incidents].each do |t|
      add_column t, :updated_at, DateTime
      from(t).update(updated_at: :created_at)
    end
  end

  down do
    %i[bingo_datacenters bingo_incidents].each { |t| drop_column t, :updated_at }
  end
end
