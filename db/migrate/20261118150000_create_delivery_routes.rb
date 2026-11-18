# Repartos R2: recorridos diarios armados por administración con pedidos mayoristas reales.
# Solo tablas nuevas: no toca pedidos, pagos, stock ni clientes. Las columnas de entrega,
# cobro y rendición (R3+) se agregan en sus etapas. Ver docs/REPARTOS_Y_RENDICIONES.md.
class CreateDeliveryRoutes < ActiveRecord::Migration[7.1]
  def change
    create_table :delivery_routes do |t|
      t.date :date, null: false
      t.references :driver, foreign_key: { to_table: :users }
      t.string :status, null: false, default: "draft"
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.text :notes
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    # Un recorrido por repartidor y por día; sin repartidor asignado, uno por día.
    add_index :delivery_routes, [:date, :driver_id], unique: true, where: "driver_id IS NOT NULL", name: "index_delivery_routes_on_date_and_driver"
    add_index :delivery_routes, :date, unique: true, where: "driver_id IS NULL", name: "index_delivery_routes_on_date_without_driver"
    add_check_constraint :delivery_routes, "status IN ('draft', 'in_progress', 'submitted', 'confirmed')", name: "delivery_routes_status_valid"

    create_table :delivery_stops do |t|
      t.references :delivery_route, null: false, foreign_key: true
      t.integer :position, null: false
      t.string :kind, null: false
      t.references :order, foreign_key: true
      t.references :customer, foreign_key: true
      t.string :title
      t.string :address
      t.text :notes
      t.datetime :removed_at
      t.references :removed_by, foreign_key: { to_table: :users }
      t.string :removal_kind
      t.text :removal_reason
      t.timestamps
    end
    # Un pedido no puede estar en dos paradas vigentes (de ningún recorrido).
    add_index :delivery_stops, :order_id, unique: true, where: "order_id IS NOT NULL AND removed_at IS NULL", name: "index_delivery_stops_on_active_order"
    add_index :delivery_stops, [:delivery_route_id, :position]
    add_check_constraint :delivery_stops, "kind IN ('order', 'supplies_pickup', 'purchase', 'errand', 'other')", name: "delivery_stops_kind_valid"
    add_check_constraint :delivery_stops, "(kind = 'order') = (order_id IS NOT NULL)", name: "delivery_stops_order_matches_kind"
    add_check_constraint :delivery_stops, "kind = 'order' OR title IS NOT NULL", name: "delivery_stops_manual_has_title"
    add_check_constraint :delivery_stops, "removed_at IS NULL OR removal_kind IS NOT NULL", name: "delivery_stops_removed_has_kind"

    create_table :delivery_events do |t|
      t.references :delivery_route, null: false, foreign_key: true
      t.references :delivery_stop, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :event_type, null: false
      t.jsonb :data, null: false, default: {}
      t.text :reason
      t.datetime :created_at, null: false
    end
  end
end
