# Etapa 1 de la tienda online: origen y confirmación de los pedidos minoristas.
#
# - source: "manual" (cargado por el equipo) | "store" (futura tienda online).
# - confirmation_status: "awaiting" | "confirmed" | "rejected", independiente del estado
#   operativo (status) y del de pago (payment_status). Solo los confirmados cuentan para
#   producción y stock (ver RetailOrder.committed).
# - request_token: idempotencia del futuro checkout (único). public_token: identificador no
#   predecible para la futura pantalla de confirmación pública (único).
#
# Los pedidos existentes quedan "manual" + "confirmed" (los defaults de columna), con la
# confirmación fechada en su alta y atribuida a quien lo creó: su comportamiento no cambia.
class AddConfirmationToRetailOrders < ActiveRecord::Migration[7.1]
  def up
    change_table :retail_orders, bulk: true do |t|
      t.string :source, null: false, default: "manual"
      t.string :confirmation_status, null: false, default: "confirmed"
      t.datetime :confirmed_at
      t.references :confirmed_by, foreign_key: { to_table: :users }
      t.datetime :rejected_at
      t.references :rejected_by, foreign_key: { to_table: :users }
      t.text :rejection_reason
      t.string :request_token
      t.string :public_token
    end

    execute <<~SQL
      UPDATE retail_orders
      SET confirmed_at = created_at, confirmed_by_id = created_by_id
      WHERE confirmation_status = 'confirmed' AND confirmed_at IS NULL
    SQL

    add_index :retail_orders, :confirmation_status
    add_index :retail_orders, :source
    add_index :retail_orders, :request_token, unique: true, where: "request_token IS NOT NULL"
    add_index :retail_orders, :public_token, unique: true, where: "public_token IS NOT NULL"

    add_check_constraint :retail_orders, "source IN ('manual', 'store')", name: "retail_orders_source_valid"
    add_check_constraint :retail_orders, "confirmation_status IN ('awaiting', 'confirmed', 'rejected')", name: "retail_orders_confirmation_status_valid"
    add_check_constraint :retail_orders, "confirmation_status <> 'confirmed' OR confirmed_at IS NOT NULL", name: "retail_orders_confirmed_has_date"
    add_check_constraint :retail_orders, "confirmation_status <> 'rejected' OR (rejected_at IS NOT NULL AND rejection_reason IS NOT NULL)", name: "retail_orders_rejected_has_reason"

    create_table :retail_order_confirmation_changes do |t|
      t.references :retail_order, null: false, foreign_key: true
      t.string :from_status, null: false
      t.string :to_status, null: false
      t.references :user, foreign_key: true
      t.text :note
      t.datetime :created_at, null: false
    end
  end

  def down
    drop_table :retail_order_confirmation_changes
    remove_check_constraint :retail_orders, name: "retail_orders_rejected_has_reason"
    remove_check_constraint :retail_orders, name: "retail_orders_confirmed_has_date"
    remove_check_constraint :retail_orders, name: "retail_orders_confirmation_status_valid"
    remove_check_constraint :retail_orders, name: "retail_orders_source_valid"
    change_table :retail_orders, bulk: true do |t|
      t.remove :public_token, :request_token, :rejection_reason, :rejected_at, :confirmed_at, :confirmation_status, :source
      t.remove_references :rejected_by, foreign_key: { to_table: :users }
      t.remove_references :confirmed_by, foreign_key: { to_table: :users }
    end
  end
end
