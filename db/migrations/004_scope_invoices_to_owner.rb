Sequel.migration do
  change do
    alter_table(:invoices) do
      add_foreign_key :owner_id,  :users,   type: :Bignum, on_delete: :restrict
      add_foreign_key :client_id, :clients, type: :Bignum, on_delete: :restrict
      add_column :issuer_snapshot,  :jsonb
      add_column :snapshot_version, Integer, null: false, default: 1
      add_column :voided_at,        DateTime
      add_column :voided_reason,    String, text: true

      add_unique_constraint [:owner_id, :number], name: :invoices_owner_number_uniq
    end

    # Drop the original global-unique constraint on (number). Postgres names
    # unique constraints from `unique: true` as `<table>_<column>_key`. Use raw
    # SQL with IF EXISTS so this no-ops if the name ever differs.
    run "ALTER TABLE invoices DROP CONSTRAINT IF EXISTS invoices_number_key"

    alter_table(:invoices) do
      add_index [:owner_id, Sequel.desc(:created_at)], name: :invoices_owner_created_idx
    end
  end
end
