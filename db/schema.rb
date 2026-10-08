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

ActiveRecord::Schema[7.1].define(version: 2026_10_08_150001) do
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

  create_table "customer_payments", force: :cascade do |t|
    t.bigint "customer_id", null: false
    t.integer "amount_cents", null: false
    t.date "paid_on", null: false
    t.string "payment_method", null: false
    t.string "reference"
    t.text "note"
    t.bigint "user_id", null: false
    t.datetime "voided_at"
    t.bigint "voided_by_id"
    t.text "void_reason"
    t.string "request_token"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["customer_id", "paid_on"], name: "index_customer_payments_on_customer_id_and_paid_on"
    t.index ["customer_id"], name: "index_customer_payments_on_customer_id"
    t.index ["request_token"], name: "index_customer_payments_on_request_token", unique: true
    t.index ["user_id"], name: "index_customer_payments_on_user_id"
    t.index ["voided_by_id"], name: "index_customer_payments_on_voided_by_id"
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
    t.jsonb "exceptional_available_dates", default: [], null: false
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
    t.bigint "customer_payment_id"
    t.string "application_kind"
    t.bigint "user_id"
    t.datetime "voided_at"
    t.text "void_reason"
    t.index ["customer_payment_id"], name: "index_payments_on_customer_payment_id"
    t.index ["order_id"], name: "index_payments_on_order_id"
    t.index ["paid_at"], name: "index_payments_on_paid_at"
    t.index ["user_id"], name: "index_payments_on_user_id"
    t.index ["voided_at"], name: "index_payments_on_voided_at"
  end

  create_table "preparations", force: :cascade do |t|
    t.string "name", null: false
    t.decimal "yield_quantity", precision: 12, scale: 3, null: false
    t.string "yield_unit", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "stock_only", default: false, null: false
    t.index ["name"], name: "index_preparations_on_name"
  end

  create_table "product_recipes", force: :cascade do |t|
    t.bigint "product_id", null: false
    t.decimal "yield_quantity", precision: 12, scale: 3, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["product_id"], name: "index_product_recipes_on_product_id", unique: true
  end

  create_table "product_stock_sources", force: :cascade do |t|
    t.bigint "product_id", null: false
    t.bigint "preparation_id", null: false
    t.decimal "quantity", precision: 12, scale: 3, default: "1.0", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["preparation_id"], name: "index_product_stock_sources_on_preparation_id"
    t.index ["product_id", "preparation_id"], name: "index_product_stock_sources_on_product_id_and_preparation_id", unique: true
    t.index ["product_id"], name: "index_product_stock_sources_on_product_id"
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
    t.string "cost_source", default: "manual", null: false
    t.boolean "sell_without_stock", default: true, null: false
    t.index ["category_id"], name: "index_products_on_category_id"
  end

  create_table "push_subscriptions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "endpoint", null: false
    t.string "p256dh_key", null: false
    t.string "auth_key", null: false
    t.string "device_label"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["endpoint"], name: "index_push_subscriptions_on_endpoint", unique: true
    t.index ["user_id"], name: "index_push_subscriptions_on_user_id"
  end

  create_table "raw_material_cost_changes", force: :cascade do |t|
    t.bigint "raw_material_id", null: false
    t.integer "previous_purchase_price_cents", null: false
    t.integer "new_purchase_price_cents", null: false
    t.decimal "previous_purchase_quantity", precision: 12, scale: 3, null: false
    t.decimal "new_purchase_quantity", precision: 12, scale: 3, null: false
    t.string "previous_purchase_unit", null: false
    t.string "new_purchase_unit", null: false
    t.string "previous_base_unit", null: false
    t.string "new_base_unit", null: false
    t.integer "previous_unit_cost_cents", null: false
    t.integer "new_unit_cost_cents", null: false
    t.bigint "changed_by_user_id"
    t.text "note"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["raw_material_id"], name: "index_raw_material_cost_changes_on_raw_material_id"
  end

  create_table "raw_materials", force: :cascade do |t|
    t.string "name", null: false
    t.string "category"
    t.string "brand"
    t.string "supplier"
    t.integer "purchase_price_cents", null: false
    t.decimal "purchase_quantity", precision: 12, scale: 3, null: false
    t.string "purchase_unit", null: false
    t.string "base_unit", null: false
    t.integer "unit_cost_cents", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_raw_materials_on_name"
  end

  create_table "recipe_components", force: :cascade do |t|
    t.string "owner_type", null: false
    t.bigint "owner_id", null: false
    t.string "component_type", null: false
    t.bigint "component_id", null: false
    t.decimal "quantity", precision: 12, scale: 3, null: false
    t.string "unit", null: false
    t.integer "position"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["component_type", "component_id"], name: "index_recipe_components_on_component"
    t.index ["owner_type", "owner_id"], name: "index_recipe_components_on_owner"
  end

  create_table "stock_items", force: :cascade do |t|
    t.string "stockable_type", null: false
    t.bigint "stockable_id", null: false
    t.decimal "quantity", precision: 12, scale: 3, default: "0.0", null: false
    t.decimal "minimum_quantity", precision: 12, scale: 3, default: "0.0", null: false
    t.boolean "active", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.decimal "production_batch_size", precision: 12, scale: 3
    t.date "stock_tracking_started_on", null: false
    t.index ["stockable_type", "stockable_id"], name: "index_stock_items_on_stockable_type_and_stockable_id", unique: true
  end

  create_table "stock_movements", force: :cascade do |t|
    t.bigint "stock_item_id", null: false
    t.string "movement_type", null: false
    t.decimal "quantity", precision: 12, scale: 3, null: false
    t.decimal "resulting_quantity", precision: 12, scale: 3, null: false
    t.bigint "order_id"
    t.bigint "user_id"
    t.text "note"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_stock_movements_on_order_id"
    t.index ["stock_item_id", "order_id"], name: "index_stock_movements_on_stock_item_id_and_order_id"
    t.index ["stock_item_id"], name: "index_stock_movements_on_stock_item_id"
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

  add_foreign_key "customer_payments", "customers"
  add_foreign_key "customer_payments", "users"
  add_foreign_key "customer_payments", "users", column: "voided_by_id"
  add_foreign_key "order_events", "orders"
  add_foreign_key "order_events", "users"
  add_foreign_key "order_items", "orders"
  add_foreign_key "order_items", "products"
  add_foreign_key "orders", "customers"
  add_foreign_key "payments", "customer_payments"
  add_foreign_key "payments", "orders"
  add_foreign_key "payments", "users"
  add_foreign_key "product_recipes", "products"
  add_foreign_key "product_stock_sources", "preparations"
  add_foreign_key "product_stock_sources", "products"
  add_foreign_key "products", "categories"
  add_foreign_key "push_subscriptions", "users"
  add_foreign_key "raw_material_cost_changes", "raw_materials"
  add_foreign_key "raw_material_cost_changes", "users", column: "changed_by_user_id"
  add_foreign_key "stock_movements", "orders"
  add_foreign_key "stock_movements", "stock_items"
  add_foreign_key "stock_movements", "users"
end
