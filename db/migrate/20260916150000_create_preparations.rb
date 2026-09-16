class CreatePreparations < ActiveRecord::Migration[7.1]
  def change
    create_table :preparations do |t|
      t.string :name, null: false
      t.decimal :yield_quantity, precision: 12, scale: 3, null: false
      # Canónica (kg/l/un), mismo criterio que RawMaterial#base_unit — el
      # rendimiento queda siempre en una unidad de referencia comparable,
      # aunque los componentes se consuman en g/ml/etc.
      t.string :yield_unit, null: false
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :preparations, :name
  end
end
