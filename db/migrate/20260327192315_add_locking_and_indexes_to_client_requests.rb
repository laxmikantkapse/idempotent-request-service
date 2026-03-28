class AddLockingAndIndexesToClientRequests < ActiveRecord::Migration[7.0]
  def change
    add_column :client_requests, :lock_version, :integer, default: 0, null: false

    # Used by the stale job recovery query: WHERE status='processing' AND updated_at < X
    add_index :client_requests, [:status, :updated_at]

    # DB-level enum constraint (belt and suspenders beyond Rails validation)
    add_check_constraint :client_requests,
      "status IN ('pending','processing','completed','failed','cancelled')",
      name: 'chk_client_requests_status'
  end
end
