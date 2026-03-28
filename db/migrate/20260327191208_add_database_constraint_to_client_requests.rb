class AddDatabaseConstraintToClientRequests < ActiveRecord::Migration[7.0]
  def change
    # Belt-and-suspenders: enforced at DB level too, not just Rails validation
    add_check_constraint :client_requests,
      "status IN ('pending','processing','completed','failed','cancelled')",
      name: 'check_status_values'
  end
end
