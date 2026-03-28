# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.0].define(version: 2026_03_27_192315) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "client_requests", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "idempotency_key", null: false
    t.string "status", default: "pending", null: false
    t.string "request_type", null: false
    t.jsonb "payload", default: {}, null: false
    t.jsonb "result", default: {}
    t.string "error_message"
    t.integer "retry_count", default: 0, null: false
    t.datetime "processed_at"
    t.datetime "cancelled_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "lock_version", default: 0, null: false
    t.index ["created_at"], name: "index_client_requests_on_created_at"
    t.index ["idempotency_key"], name: "index_client_requests_on_idempotency_key", unique: true
    t.index ["status", "updated_at"], name: "index_client_requests_on_status_and_updated_at"
    t.index ["status"], name: "index_client_requests_on_status"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'processing'::character varying, 'completed'::character varying, 'failed'::character varying, 'cancelled'::character varying]::text[])", name: "check_status_values"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'processing'::character varying, 'completed'::character varying, 'failed'::character varying, 'cancelled'::character varying]::text[])", name: "chk_client_requests_status"
  end

end
