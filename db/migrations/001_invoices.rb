Sequel.migration do
  change do
    create_table(:invoices) do
      column :uuid,           :uuid,    primary_key: true
      String  :number,        null: false, unique: true
      String  :client_name,   null: false
      String  :client_email,  null: false
      String  :client_address, text: true
      String  :currency,      null: false, size: 3
      BigDecimal :gel_rate,   size: [12, 4], null: false
      BigDecimal :subtotal,   size: [14, 2], null: false
      column :items,          :jsonb, null: false
      Date    :issued_on,     null: false
      Date    :due_on,        null: false
      DateTime :paid_at
      String  :pdf_key,       null: false
      String  :notes,         text: true
      DateTime :created_at,   null: false
    end

    run "CREATE INDEX invoices_created_at_idx ON invoices (created_at DESC)"
  end
end
