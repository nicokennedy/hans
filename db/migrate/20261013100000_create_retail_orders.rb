# Módulo de Pedidos Minoristas: pedidos manuales de compradores individuales, independientes
# de los pedidos mayoristas (orders / customers / payments). Solo agrega tablas y una columna
# nullable en stock_movements; no modifica ni migra datos existentes.
class CreateRetailOrders < ActiveRecord::Migration[7.1]
  def change
    create_table :retail_orders do |t|
      t.string :buyer_name, null: false
      t.string :buyer_phone
      t.date :delivery_date, null: false
      t.string :delivery_kind, null: false, default: "pickup"
      t.string :delivery_time_note
      t.string :address
      t.text :notes
      t.string :planned_payment_method
      t.integer :shipping_cents, null: false, default: 0
      t.integer :subtotal_cents, null: false, default: 0
      t.integer :total_cents, null: false, default: 0
      # Caché de la suma de pagos activos (se recalcula en cada alta/anulación).
      t.integer :amount_paid_cents, null: false, default: 0
      t.string :status, null: false, default: "pending"
      t.string :payment_status, null: false, default: "pending"
      t.references :created_by, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :retail_orders, :delivery_date
    add_index :retail_orders, :status
    add_index :retail_orders, :payment_status

    create_table :retail_order_items do |t|
      t.references :retail_order, null: false, foreign_key: true
      # NULL = producto manual (descripción libre, sin catálogo, sin stock).
      t.references :product, foreign_key: true
      t.string :description
      t.string :product_name_snapshot, null: false
      t.integer :quantity, null: false
      t.integer :unit_price_cents, null: false
      t.integer :line_total_cents, null: false
      t.integer :position, null: false, default: 0
      t.timestamps
    end

    create_table :retail_order_payments do |t|
      t.references :retail_order, null: false, foreign_key: true
      t.date :paid_at, null: false
      t.integer :amount_cents, null: false
      t.string :payment_method, null: false
      t.text :notes
      t.references :user, foreign_key: true
      t.boolean :excess_confirmed, null: false, default: false
      t.string :request_token
      t.datetime :voided_at
      t.references :voided_by, foreign_key: { to_table: :users }
      t.text :void_reason
      t.timestamps
    end
    add_index :retail_order_payments, :request_token, unique: true, where: "request_token IS NOT NULL"

    create_table :retail_order_status_changes do |t|
      t.references :retail_order, null: false, foreign_key: true
      t.string :from_status
      t.string :to_status, null: false
      t.references :user, foreign_key: true
      t.text :note
      t.datetime :created_at, null: false
    end

    add_reference :stock_movements, :retail_order, foreign_key: true, null: true
  end
end
