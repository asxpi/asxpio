Sequel.migration do
  change do
    # Created as "invite-<hex>"; the invitee picks the real username when
    # accepting the invite.
    add_column :users, :choose_username, TrueClass, null: false, default: false
  end
end
