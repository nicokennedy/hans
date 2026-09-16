class CreateRawMaterials < ActiveRecord::Migration[7.1]
  def change
    create_table :raw_materials do |t|
      t.string :name, null: false
      t.string :category
      t.string :brand
      t.string :supplier

      t.integer :purchase_price_cents, null: false
      t.decimal :purchase_quantity, precision: 12, scale: 3, null: false
      t.string :purchase_unit, null: false
      t.string :base_unit, null: false

      # Derivado: purchase_price_cents / (purchase_quantity convertida a
      # base_unit). Nunca se carga a mano — lo recalcula el modelo siempre
      # que cambia algún dato de compra.
      t.integer :unit_cost_cents, null: false

      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :raw_materials, :name
  end
end
