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

ActiveRecord::Schema[7.1].define(version: 2026_07_22_135226) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_stat_statements"
  enable_extension "plpgsql"

  create_table "blocked_dates", force: :cascade do |t|
    t.date "date"
    t.string "reason"
    t.boolean "active"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "categories", force: :cascade do |t|
    t.string "name"
    t.integer "position"
    t.boolean "active"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "customers", force: :cascade do |t|
    t.string "name"
    t.string "contact_name"
    t.string "email"
    t.string "phone"
    t.string "address"
    t.string "payment_terms"
    t.text "internal_notes"
    t.boolean "active"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "delivery_settings", force: :cascade do |t|
    t.integer "cutoff_hour"
    t.jsonb "unavailable_weekdays"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "order_events", force: :cascade do |t|
    t.bigint "order_id", null: false
    t.bigint "user_id", null: false
    t.string "event_type"
    t.string "field_name"
    t.text "old_value"
    t.text "new_value"
    t.text "reason"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_order_events_on_order_id"
    t.index ["user_id"], name: "index_order_events_on_user_id"
  end

  create_table "order_items", force: :cascade do |t|
    t.bigint "order_id", null: false
    t.bigint "product_id", null: false
    t.string "product_name_snapshot"
    t.string "category_name_snapshot"
    t.integer "quantity"
    t.integer "unit_price_cents_snapshot"
    t.integer "unit_cost_cents_snapshot"
    t.integer "line_revenue_cents"
    t.integer "line_cost_cents"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_order_items_on_order_id"
    t.index ["product_id"], name: "index_order_items_on_product_id"
  end

  create_table "orders", force: :cascade do |t|
    t.string "number"
    t.bigint "customer_id", null: false
    t.date "delivery_date"
    t.string "status"
    t.string "payment_method_selected"
    t.string "payment_status"
    t.integer "amount_paid_cents"
    t.datetime "paid_at"
    t.text "customer_comment"
    t.text "internal_note"
    t.integer "total_cents"
    t.boolean "created_by_admin"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["customer_id"], name: "index_orders_on_customer_id"
  end

  create_table "payments", force: :cascade do |t|
    t.bigint "order_id", null: false
    t.integer "amount_cents", null: false
    t.datetime "paid_at", null: false
    t.string "payment_method", null: false
    t.text "note"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_payments_on_order_id"
    t.index ["paid_at"], name: "index_payments_on_paid_at"
  end

  create_table "products", force: :cascade do |t|
    t.string "name"
    t.text "description"
    t.integer "price_cents"
    t.integer "cost_cents"
    t.bigint "category_id", null: false
    t.boolean "active"
    t.integer "position"
    t.string "unit"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "internal_category"
    t.string "public_category"
    t.index ["category_id"], name: "index_products_on_category_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.string "role"
    t.bigint "customer_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["customer_id"], name: "index_users_on_customer_id"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  add_foreign_key "order_events", "orders"
  add_foreign_key "order_events", "users"
  add_foreign_key "order_items", "orders"
  add_foreign_key "order_items", "products"
  add_foreign_key "orders", "customers"
  add_foreign_key "payments", "orders"
  add_foreign_key "products", "categories"
end
