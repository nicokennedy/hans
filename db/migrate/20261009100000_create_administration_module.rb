# Módulo de Administración: proveedores, compras con ítems, gastos (con recurrencias),
# obligaciones, pagos a proveedores e imputaciones. SOLO tablas nuevas: no toca ninguna
# tabla existente (stock, materias primas, recetas, costos, pedidos).
#
# Diseño:
#  - obligations: la deuda (una por compra o gasto, UNIQUE por origen). El saldo NUNCA
#    se guarda: es amount_cents menos las imputaciones vigentes.
#  - outgoing_payments + outgoing_payment_applications: un pago se registra una vez y se
#    imputa a una o más obligaciones; lo no imputado es anticipo del proveedor.
#  - purchase_items.raw_material_id: vínculo FUTURO y opcional con una materia prima
#    (etapa 2). Hoy nadie lo lee ni lo escribe.
class CreateAdministrationModule < ActiveRecord::Migration[7.1]
  DEFAULT_CATEGORIES = [
    "Alquiler", "Sueldos y jornales", "Servicios", "Impuestos", "Limpieza y mantenimiento",
    "Logística y envíos", "Honorarios", "Gastos bancarios", "Publicidad y marketing", "Otros"
  ].freeze

  def up
    create_table :suppliers do |t|
      t.string :name, null: false
      t.string :tax_id
      t.string :email
      t.string :phone
      t.string :address
      t.text :notes
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :suppliers, :name
    add_index :suppliers, :tax_id, unique: true, where: "tax_id IS NOT NULL AND tax_id <> ''", name: "index_suppliers_on_tax_id_unique"

    create_table :expense_categories do |t|
      t.string :name, null: false
      t.boolean :active, null: false, default: true
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :expense_categories, "lower(name)", unique: true, name: "index_expense_categories_on_lower_name"

    create_table :expense_recurrences do |t|
      t.references :supplier, foreign_key: true
      t.references :expense_category, null: false, foreign_key: true
      t.bigint :amount_cents, null: false
      t.text :notes
      t.string :document_type
      t.string :frequency, null: false
      t.date :starts_on, null: false
      t.date :ends_on
      t.integer :max_occurrences
      t.integer :due_days, null: false, default: 0
      t.boolean :active, null: false, default: true
      t.references :user, foreign_key: true
      t.timestamps
    end
    add_check_constraint :expense_recurrences, "amount_cents > 0", name: "expense_recurrences_amount_positive"

    create_table :purchases do |t|
      t.bigint :subtotal_cents, null: false, default: 0
      t.bigint :discount_cents, null: false, default: 0
      t.bigint :taxes_cents, null: false, default: 0
      t.bigint :adjustments_cents, null: false, default: 0
      t.timestamps
    end
    add_check_constraint :purchases, "discount_cents >= 0 AND taxes_cents >= 0", name: "purchases_adjustments_non_negative"

    create_table :purchase_items do |t|
      t.references :purchase, null: false, foreign_key: true
      t.integer :position, null: false, default: 0
      t.string :description, null: false
      t.decimal :quantity, precision: 14, scale: 3, null: false
      t.string :unit, null: false
      t.bigint :unit_price_cents, null: false
      t.bigint :subtotal_cents, null: false
      # Reservado para la etapa 2 (vincular el ítem con una materia prima). No operativo.
      t.references :raw_material, foreign_key: true
      t.timestamps
    end
    add_check_constraint :purchase_items, "quantity > 0 AND unit_price_cents >= 0", name: "purchase_items_positive"

    create_table :expenses do |t|
      t.references :expense_category, null: false, foreign_key: true
      t.references :expense_recurrence, foreign_key: true
      t.date :occurrence_on
      t.timestamps
    end
    add_index :expenses, [:expense_recurrence_id, :occurrence_on], unique: true, where: "expense_recurrence_id IS NOT NULL", name: "index_expenses_on_recurrence_occurrence"

    create_table :obligations do |t|
      t.references :supplier, foreign_key: true
      t.string :source_type, null: false
      t.bigint :source_id, null: false
      t.bigint :amount_cents, null: false
      t.date :accrual_on, null: false
      t.date :due_on
      t.string :document_type
      t.string :document_number
      t.text :notes
      t.references :user, foreign_key: true
      t.datetime :voided_at
      t.references :voided_by, foreign_key: { to_table: :users }
      t.text :void_reason
      t.timestamps
    end
    add_index :obligations, [:source_type, :source_id], unique: true
    add_index :obligations, :due_on
    add_index :obligations, :accrual_on
    add_check_constraint :obligations, "amount_cents > 0", name: "obligations_amount_positive"

    create_table :outgoing_payments do |t|
      t.references :supplier, foreign_key: true
      t.bigint :amount_cents, null: false
      t.date :paid_on, null: false
      t.string :payment_method, null: false
      t.string :reference
      t.text :note
      t.references :user, null: false, foreign_key: true
      t.datetime :voided_at
      t.references :voided_by, foreign_key: { to_table: :users }
      t.text :void_reason
      t.string :request_token
      t.timestamps
    end
    add_index :outgoing_payments, :request_token, unique: true
    add_index :outgoing_payments, :paid_on
    add_check_constraint :outgoing_payments, "amount_cents > 0", name: "outgoing_payments_amount_positive"

    create_table :outgoing_payment_applications do |t|
      t.references :outgoing_payment, null: false, foreign_key: true
      t.references :obligation, null: false, foreign_key: true
      t.bigint :amount_cents, null: false
      t.string :kind, null: false
      t.references :user, foreign_key: true
      t.datetime :voided_at
      t.text :void_reason
      t.timestamps
    end
    add_check_constraint :outgoing_payment_applications, "amount_cents > 0", name: "outgoing_payment_applications_amount_positive"

    # Comprobantes adjuntos guardados en la base: el disco de Heroku es efímero y no hay
    # un servicio de almacenamiento externo configurado, así que Active Storage en disco
    # local perdería los archivos en cada reinicio.
    create_table :administration_attachments do |t|
      t.string :owner_type, null: false
      t.bigint :owner_id, null: false
      t.string :filename, null: false
      t.string :content_type, null: false
      t.integer :byte_size, null: false
      t.string :checksum, null: false
      t.binary :data, null: false
      t.references :user, foreign_key: true
      t.timestamps
    end
    add_index :administration_attachments, [:owner_type, :owner_id]

    # Categorías iniciales (idempotente por nombre, sin tocar nada existente).
    DEFAULT_CATEGORIES.each_with_index do |name, index|
      execute <<~SQL.squish
        INSERT INTO expense_categories (name, active, position, created_at, updated_at)
        SELECT #{connection.quote(name)}, TRUE, #{index}, NOW(), NOW()
        WHERE NOT EXISTS (SELECT 1 FROM expense_categories WHERE lower(name) = lower(#{connection.quote(name)}))
      SQL
    end
  end

  def down
    drop_table :administration_attachments
    drop_table :outgoing_payment_applications
    drop_table :outgoing_payments
    drop_table :obligations
    drop_table :expenses
    drop_table :purchase_items
    drop_table :purchases
    drop_table :expense_recurrences
    drop_table :expense_categories
    drop_table :suppliers
  end
end
