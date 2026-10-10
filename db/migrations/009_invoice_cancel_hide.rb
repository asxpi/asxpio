Sequel.migration do
  change do
    alter_table(:invoices) do
      add_column :cancelled_at,  DateTime                       # NULL = not cancelled
      add_column :cancel_reason, String, text: true
      add_column :hidden, TrueClass, null: false, default: false # admin: superusers only
    end
  end
end
