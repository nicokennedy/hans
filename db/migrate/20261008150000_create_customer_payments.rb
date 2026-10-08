# Pago recibido de un cliente (ej. una transferencia grande) para su cuenta
# corriente. Se registra UNA sola vez; se reparte entre pedidos mediante filas de
# `payments` (ver la migración siguiente) y lo que no se reparte queda como saldo a
# favor. Solo agrega una tabla: no toca ni recalcula ningún dato existente.
class CreateCustomerPayments < ActiveRecord::Migration[7.1]
  def change
    create_table :customer_payments do |t|
      t.references :customer, null: false, foreign_key: true
      t.integer :amount_cents, null: false
      t.date :paid_on, null: false
      t.string :payment_method, null: false
      t.string :reference
      t.text :note
      t.references :user, null: false, foreign_key: true
      # Anulación: el registro se conserva (nunca se borra), con quién, cuándo y por qué.
      t.datetime :voided_at
      t.references :voided_by, foreign_key: { to_table: :users }
      t.text :void_reason
      # Evita duplicados por doble clic / reenvío del formulario.
      t.string :request_token

      t.timestamps
    end

    add_index :customer_payments, :request_token, unique: true
    add_index :customer_payments, [:customer_id, :paid_on]
  end
end
