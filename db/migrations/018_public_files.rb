Sequel.migration do
  change do
    # Index of what the admin uploaded to the public bucket (/admin/files).
    # The bucket cannot be listed with the app's key, so this is the only
    # record of those objects.
    create_table(:public_files) do
      primary_key :id
      String    :key,          null: false, unique: true # object key: <8 hex>/<filename>
      String    :filename,     null: false               # sanitised, as in the key
      String    :content_type, null: false
      TrueClass :inline,       null: false, default: false # false = served as a download
      Bignum    :size,         null: false
      String    :sha256,       null: false
      String    :note,         text: true
      String    :uploaded_by
      DateTime  :created_at,   null: false
      DateTime  :updated_at,   null: false
    end
  end
end
