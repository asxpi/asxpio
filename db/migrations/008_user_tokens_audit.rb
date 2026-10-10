Sequel.migration do
  change do
    # One-time invite / password-reset links. Only a SHA-256 of the token
    # is stored; the raw token exists in the email and the URL.
    create_table(:user_tokens) do
      primary_key :id
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      String   :purpose,      null: false # invite | reset
      String   :token_digest, null: false, unique: true
      DateTime :expires_at,   null: false
      DateTime :used_at
      DateTime :created_at,   null: false
    end

    create_table(:audit_log) do
      primary_key :id
      foreign_key :user_id, :users, on_delete: :set_null
      String   :username            # kept after the user is deleted
      String   :action,  null: false
      String   :target
      String   :detail,  text: true
      String   :ip
      DateTime :created_at, null: false
      index :created_at
    end
  end
end
