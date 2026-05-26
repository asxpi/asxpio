Sequel.migration do
  change do
    create_table(:users) do
      primary_key :id, type: :Bignum
      column   :email,          :citext, null: false, unique: true
      String   :name,           null: false
      String   :password_hash
      DateTime :last_login_at
      DateTime :deactivated_at
      DateTime :created_at,     null: false
    end

    create_table(:password_tokens) do
      primary_key :id, type: :Bignum
      foreign_key :user_id, :users, type: :Bignum, null: false, on_delete: :cascade
      String   :token_hash, null: false, unique: true
      String   :purpose,    null: false
      DateTime :expires_at, null: false
      DateTime :used_at
      DateTime :created_at, null: false

      index [:user_id, :used_at]
    end
  end
end
