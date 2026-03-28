class CreateClientRequests < ActiveRecord::Migration[7.0]
  def change
    create_table :client_requests, id: :uuid do |t|
      t.string     :idempotency_key,  null: false
      t.string     :status,           null: false, default: 'pending'
      t.string     :request_type,     null: false
      t.jsonb      :payload,          null: false, default: {}
      t.jsonb      :result,                        default: {}
      t.string     :error_message
      t.integer    :retry_count,      null: false, default: 0
      t.datetime   :processed_at
      t.datetime   :cancelled_at
      t.timestamps
    end

    add_index :client_requests, :idempotency_key, unique: true
    add_index :client_requests, :status
    add_index :client_requests, :created_at
  end
end
