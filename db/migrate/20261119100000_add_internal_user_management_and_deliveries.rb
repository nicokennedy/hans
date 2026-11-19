# Repartos R3 + Administración → Usuarios. Solo agrega columnas y una tabla:
#  - users: nombre, activo (los existentes quedan activos), cambio de contraseña obligatorio
#    (falso para todos los existentes) y último inicio de sesión (vacío hasta el próximo).
#  - user_events: historial de altas, ediciones, cambios de rol, activaciones y contraseñas.
#  - delivery_stops: estado de la entrega registrado por el repartidor.
# No cambia pedidos, pagos, stock ni permisos existentes.
class AddInternalUserManagementAndDeliveries < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :name, :string
    add_column :users, :active, :boolean, null: false, default: true
    add_column :users, :must_change_password, :boolean, null: false, default: false
    add_column :users, :last_sign_in_at, :datetime

    create_table :user_events do |t|
      t.references :user, null: false, foreign_key: true
      t.references :actor, null: false, foreign_key: { to_table: :users }
      t.string :event_type, null: false
      t.jsonb :data, null: false, default: {}
      t.datetime :created_at, null: false
    end

    add_column :delivery_stops, :delivery_status, :string, null: false, default: "pending"
    add_column :delivery_stops, :delivery_recorded_at, :datetime
    add_reference :delivery_stops, :delivery_recorded_by, foreign_key: { to_table: :users }
    add_column :delivery_stops, :not_delivered_reason, :string
    add_check_constraint :delivery_stops, "delivery_status IN ('pending', 'delivered', 'not_delivered', 'done')", name: "delivery_stops_delivery_status_valid"
    add_check_constraint :delivery_stops, "delivery_status <> 'not_delivered' OR not_delivered_reason IS NOT NULL", name: "delivery_stops_not_delivered_has_reason"
  end
end
