# Etapa 3 de la tienda online: reglas de retiro y envío minoristas, administrables desde HANS e
# independientes del reparto mayorista (DeliverySetting / BlockedDate no se tocan).
#
# - retail_fulfillment_settings: una sola fila con la anticipación mínima (días calendario) y las
#   indicaciones del punto de retiro (vacías: la dirección exacta todavía no está definida).
# - retail_service_windows: una fila por modalidad (pickup / delivery) y día de la semana, con su
#   franja horaria en minutos desde las 00:00 (hora de Argentina).
# - retail_delivery_zones: zonas de envío elegidas a mano por el cliente, con su costo (centavos).
# - retail_service_closures: fechas puntuales sin retiro, sin envío o sin ninguno de los dos.
# - retail_orders: zona, nombre de la zona y franja quedan guardados en el pedido (histórico); el
#   costo ya se guardaba en shipping_cents. Columnas nuevas, opcionales y sin valor por defecto:
#   los pedidos existentes no cambian.
#
# Carga la configuración inicial del ticket de la Etapa 3. No modifica ni borra datos existentes.
class CreateRetailFulfillment < ActiveRecord::Migration[7.1]
  def up
    create_table :retail_fulfillment_settings do |t|
      t.integer :min_lead_days, null: false, default: 2
      t.text :pickup_point_details
      t.timestamps
    end
    add_check_constraint :retail_fulfillment_settings, "min_lead_days BETWEEN 0 AND 30", name: "retail_fulfillment_lead_days_range"

    create_table :retail_service_windows do |t|
      t.string :service, null: false
      t.integer :wday, null: false
      t.boolean :enabled, null: false, default: false
      t.integer :opens_minute
      t.integer :closes_minute
      t.timestamps
    end
    add_index :retail_service_windows, [:service, :wday], unique: true
    add_check_constraint :retail_service_windows, "service IN ('pickup', 'delivery')", name: "retail_service_windows_service_valid"
    add_check_constraint :retail_service_windows, "wday BETWEEN 0 AND 6", name: "retail_service_windows_wday_valid"
    add_check_constraint :retail_service_windows,
      "NOT enabled OR (opens_minute IS NOT NULL AND closes_minute IS NOT NULL AND opens_minute >= 0 AND closes_minute <= 1440 AND opens_minute < closes_minute)",
      name: "retail_service_windows_enabled_has_hours"

    create_table :retail_delivery_zones do |t|
      t.string :name, null: false
      t.text :coverage
      t.bigint :price_cents, null: false
      t.boolean :active, null: false, default: true
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :retail_delivery_zones, "lower(name)", unique: true, name: "index_retail_delivery_zones_on_lower_name"
    add_check_constraint :retail_delivery_zones, "price_cents >= 0", name: "retail_delivery_zones_price_non_negative"

    create_table :retail_service_closures do |t|
      t.date :date, null: false
      t.string :service, null: false
      t.string :reason
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end
    add_index :retail_service_closures, [:date, :service], unique: true
    add_check_constraint :retail_service_closures, "service IN ('pickup', 'delivery', 'all')", name: "retail_service_closures_service_valid"

    add_reference :retail_orders, :delivery_zone, foreign_key: { to_table: :retail_delivery_zones, on_delete: :restrict }
    add_column :retail_orders, :delivery_zone_name, :string
    add_column :retail_orders, :delivery_window_label, :string

    seed_initial_configuration
  end

  def down
    remove_column :retail_orders, :delivery_window_label
    remove_column :retail_orders, :delivery_zone_name
    remove_reference :retail_orders, :delivery_zone, foreign_key: { to_table: :retail_delivery_zones }
    drop_table :retail_service_closures
    drop_table :retail_delivery_zones
    drop_table :retail_service_windows
    drop_table :retail_fulfillment_settings
  end

  private

  # Misma configuración que RetailFulfillment::Defaults (la que usan los tests y una base nueva).
  # Retiro: lunes a viernes 14:00–17:00, sábados 11:00–13:00. Envío: lunes a sábado 8:30–13:00.
  # Domingos sin servicio. Anticipación: 2 días calendario. Zonas 1/2/3: $5.000 / $6.000 / $7.000.
  def seed_initial_configuration
    execute <<~SQL
      INSERT INTO retail_fulfillment_settings (min_lead_days, pickup_point_details, created_at, updated_at)
      VALUES (2, NULL, NOW(), NOW());
    SQL

    windows = []
    (0..6).each do |wday|
      pickup = case wday
               when 1..5 then [840, 1020]
               when 6 then [660, 780]
               end
      delivery = (1..6).cover?(wday) ? [510, 780] : nil
      windows << ["pickup", wday, pickup]
      windows << ["delivery", wday, delivery]
    end
    values = windows.map do |service, wday, hours|
      opens, closes = hours
      "('#{service}', #{wday}, #{hours ? 'TRUE' : 'FALSE'}, #{opens || 'NULL'}, #{closes || 'NULL'}, NOW(), NOW())"
    end
    execute "INSERT INTO retail_service_windows (service, wday, enabled, opens_minute, closes_minute, created_at, updated_at) VALUES #{values.join(', ')};"

    execute <<~SQL
      INSERT INTO retail_delivery_zones (name, coverage, price_cents, active, position, created_at, updated_at) VALUES
        ('Zona 1', 'Costa, Independencia, Colón, Vértiz', 500000, TRUE, 1, NOW(), NOW()),
        ('Zona 2', 'Centro, zona Facultad', 600000, TRUE, 2, NOW(), NOW()),
        ('Zona 3', 'Constitución, barrios privados, Champagnat hasta Allio', 700000, TRUE, 3, NOW(), NOW());
    SQL
  end
end
