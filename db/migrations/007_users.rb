Sequel.migration do
  change do
    create_table(:users) do
      primary_key :id
      String   :username,      null: false, unique: true  # login, lowercase
      String   :email,         unique: true                # invites / resets
      String   :name
      String   :password_digest                            # NULL until an invite is accepted
      TrueClass :superuser,    null: false, default: false
      TrueClass :active,       null: false, default: true
      Integer  :session_version, null: false, default: 1   # bump = log out everywhere
      TrueClass :must_change_password, null: false, default: false
      DateTime :last_login_at
      DateTime :created_at,    null: false
    end

    # One row per user and area; flags are independent (read + delete
    # without write is allowed). Superusers ignore this table.
    create_table(:user_permissions) do
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      String    :area,       null: false
      TrueClass :can_read,   null: false, default: false
      TrueClass :can_write,  null: false, default: false
      TrueClass :can_delete, null: false, default: false
      primary_key [:user_id, :area]
    end
  end
end
