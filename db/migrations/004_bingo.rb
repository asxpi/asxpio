Sequel.migration do
  change do
    # Datacenter bingo (served on BINGO_HOST). Localized fields are plain
    # per-locale columns; ru is the source of truth, en/uk fall back to it.
    create_table(:bingo_datacenters) do
      primary_key :id
      String  :slug,         null: false, unique: true
      Integer :position,     null: false
      String  :name_ru,      null: false
      String  :name_en
      String  :name_uk
      String  :city_ru,      null: false
      String  :city_en
      String  :city_uk
      String  :operator,     null: false
      String  :mw                       # free-form number: "64", "≈36", "25–30"
      String  :status,       null: false, default: 'operational' # | building
      Integer :year
      String  :photo_key                # MinIO key under bingo/
      String  :photo_source_url, text: true
      String  :photo_credit
      String  :info_url,     text: true
      DateTime :created_at,  null: false
    end

    create_table(:bingo_incidents) do
      primary_key :id
      foreign_key :datacenter_id, :bingo_datacenters, null: false, on_delete: :cascade
      Date    :occurred_on,  null: false
      String  :kind,         null: false # strike | fire | outage | flood | cooling | other
      String  :title_ru,     null: false
      String  :title_en
      String  :title_uk
      String  :url,          text: true
      DateTime :created_at,  null: false
      index :datacenter_id
    end
  end
end
