# Repartos R4: cobros en efectivo, fotos de remitos, gastos y rendición de cada recorrido.
# Solo agrega tablas y columnas; no modifica filas existentes.
#
#  - delivery_collections: cada cobro del repartidor. El dinero en sí es un CustomerPayment
#    (cuenta corriente existente, efectivo contraentrega); esta tabla lo vincula con el
#    recorrido, la parada, el repartidor y el modo ("a identificar"). Las correcciones anulan
#    (voided_*) y crean uno nuevo que apunta al anterior (replaces_id). Nunca se borran.
#  - delivery_photos: foto del remito firmado (Active Storage), por parada.
#  - delivery_expenses: gastos pagados con el efectivo del recorrido. Pasan a Administración
#    (Expense) una sola vez, al confirmar el cierre (expense_id único).
#  - delivery_stops: la respuesta a "¿Te pagaron?" y la excepción de la foto del remito.
#  - delivery_routes: envío de la rendición y cierre (totales congelados, efectivo contado,
#    diferencia de caja e importe pendiente de resolver).
class CreateDeliveryCollectionsExpensesAndSettlements < ActiveRecord::Migration[7.1]
  def change
    create_table :delivery_collections do |t|
      t.references :delivery_route, null: false, foreign_key: true
      t.references :delivery_stop, null: false, foreign_key: true
      t.references :customer, null: false, foreign_key: true
      t.references :customer_payment, null: false, foreign_key: true, index: { unique: true }
      t.integer :amount_cents, null: false
      t.integer :credit_cents, null: false, default: 0
      t.string :mode, null: false
      t.jsonb :allocations, null: false, default: {}
      t.string :request_token, null: false
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.references :replaces, foreign_key: { to_table: :delivery_collections }
      t.datetime :voided_at
      t.references :voided_by, foreign_key: { to_table: :users }
      t.text :void_reason
      t.timestamps
    end
    add_index :delivery_collections, :request_token, unique: true
    add_check_constraint :delivery_collections, "mode IN ('allocated', 'unidentified')", name: "delivery_collections_mode_valid"
    add_check_constraint :delivery_collections, "amount_cents > 0 AND credit_cents >= 0 AND credit_cents <= amount_cents", name: "delivery_collections_amounts_valid"
    add_check_constraint :delivery_collections, "voided_at IS NULL OR void_reason IS NOT NULL", name: "delivery_collections_void_has_reason"

    create_table :delivery_photos do |t|
      t.references :delivery_route, null: false, foreign_key: true
      t.references :delivery_stop, null: false, foreign_key: true
      t.string :kind, null: false, default: "signed_receipt"
      t.string :request_token, null: false
      t.references :taken_by, null: false, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :delivery_photos, :request_token, unique: true

    create_table :delivery_expenses do |t|
      t.references :delivery_route, null: false, foreign_key: true
      t.string :concept, null: false
      t.integer :amount_cents, null: false
      t.datetime :spent_at, null: false
      t.text :notes
      t.boolean :admin_exception, null: false, default: false
      t.text :exception_reason
      t.string :request_token, null: false
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.references :replaces, foreign_key: { to_table: :delivery_expenses }
      t.datetime :voided_at
      t.references :voided_by, foreign_key: { to_table: :users }
      t.text :void_reason
      t.references :expense, foreign_key: true, index: { unique: true }
      t.timestamps
    end
    add_index :delivery_expenses, :request_token, unique: true
    add_check_constraint :delivery_expenses, "amount_cents > 0", name: "delivery_expenses_amount_positive"
    add_check_constraint :delivery_expenses, "voided_at IS NULL OR void_reason IS NOT NULL", name: "delivery_expenses_void_has_reason"
    add_check_constraint :delivery_expenses, "NOT admin_exception OR exception_reason IS NOT NULL", name: "delivery_expenses_exception_has_reason"

    add_column :delivery_stops, :payment_report, :string
    add_column :delivery_stops, :payment_reported_at, :datetime
    add_column :delivery_stops, :receipt_exception, :string
    add_column :delivery_stops, :receipt_exception_at, :datetime
    add_reference :delivery_stops, :receipt_exception_by, foreign_key: { to_table: :users }

    add_column :delivery_routes, :submitted_at, :datetime
    add_reference :delivery_routes, :submitted_by, foreign_key: { to_table: :users }
    add_column :delivery_routes, :confirmed_at, :datetime
    add_reference :delivery_routes, :confirmed_by, foreign_key: { to_table: :users }
    add_column :delivery_routes, :collected_cents, :integer
    add_column :delivery_routes, :expenses_cents, :integer
    add_column :delivery_routes, :expected_cash_cents, :integer
    add_column :delivery_routes, :counted_cash_cents, :integer
    add_column :delivery_routes, :difference_cents, :integer
    add_column :delivery_routes, :unresolved_cents, :integer
    add_column :delivery_routes, :confirmation_note, :text
  end
end
