class CreateRawMaterialCostChanges < ActiveRecord::Migration[7.1]
  def change
    # Historial append-only: un registro por cada actualización de
    # RawMaterial que efectivamente cambia el unit_cost_cents resultante
    # (precio, cantidad, unidad de compra o unidad base pueden ser la causa
    # — se guardan todos para poder explicar el cambio, no solo el precio).
    create_table :raw_material_cost_changes do |t|
      t.bigint :raw_material_id, null: false

      t.integer :previous_purchase_price_cents, null: false
      t.integer :new_purchase_price_cents, null: false
      t.decimal :previous_purchase_quantity, precision: 12, scale: 3, null: false
      t.decimal :new_purchase_quantity, precision: 12, scale: 3, null: false
      t.string :previous_purchase_unit, null: false
      t.string :new_purchase_unit, null: false
      t.string :previous_base_unit, null: false
      t.string :new_base_unit, null: false
      t.integer :previous_unit_cost_cents, null: false
      t.integer :new_unit_cost_cents, null: false

      t.bigint :changed_by_user_id
      t.text :note

      t.timestamps
    end

    add_index :raw_material_cost_changes, :raw_material_id
    add_foreign_key :raw_material_cost_changes, :raw_materials
    add_foreign_key :raw_material_cost_changes, :users, column: :changed_by_user_id
  end
end
