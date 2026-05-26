Sequel.migration do
  change do
    create_table(:issuer_profiles) do
      foreign_key :user_id, :users, type: :Bignum, primary_key: true,
                  on_delete: :restrict
      String   :legal_name
      String   :legal_name_local
      String   :tax_id
      String   :reg_number
      Date     :registered_on
      String   :address,          text: true
      String   :contact_email
      String   :contact_phone
      String   :bank_name
      String   :bank_iban
      String   :bank_swift
      String   :invoice_prefix,   null: false, default: 'INV'
      String   :default_currency, null: false, default: 'USD', size: 3
      Integer  :default_due_days, null: false, default: 14
      String   :default_notes,    text: true
      DateTime :updated_at,       null: false
    end

    create_table(:clients) do
      primary_key :id, type: :Bignum
      foreign_key :owner_id, :users, type: :Bignum, null: false,
                  on_delete: :restrict
      String   :name,            null: false
      String   :email,           null: false
      String   :address,         text: true
      String   :default_currency, size: 3
      Integer  :default_due_days
      String   :default_notes,   text: true
      DateTime :archived_at
      DateTime :created_at,      null: false
    end

    run "CREATE UNIQUE INDEX clients_owner_email_idx ON clients (owner_id, lower(email))"
    run "CREATE INDEX clients_owner_active_idx ON clients (owner_id) WHERE archived_at IS NULL"
  end
end
