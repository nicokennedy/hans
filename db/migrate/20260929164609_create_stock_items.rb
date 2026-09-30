class CreateStockItems < ActiveRecord::Migration[7.1]
  def change
    create_table :stock_items do |t|
      t.string :stockable_type, null: false
      t.bigint :stockable_id, null: false
      t.decimal :quantity, precision: 12, scale: 3, null: false, default: 0
      t.decimal :minimum_quantity, precision: 12, scale: 3, null: false, default: 0
      # false por default a propósito (ver punto 19 del pedido): ningún
      # Product/Preparation existente empieza a controlar stock solo por
      # correr esta migración. Se activa explícitamente desde Admin.
      t.boolean :active, null: false, default: false
      t.timestamps
    end

    add_index :stock_items, [:stockable_type, :stockable_id], unique: true
  end
end
