class CreateStockMovements < ActiveRecord::Migration[7.1]
  def change
    create_table :stock_movements do |t|
      t.bigint :stock_item_id, null: false
      t.string :movement_type, null: false
      t.decimal :quantity, precision: 12, scale: 3, null: false
      t.decimal :resulting_quantity, precision: 12, scale: 3, null: false
      t.bigint :order_id
      t.bigint :user_id
      t.text :note
      t.timestamps
    end

    add_index :stock_movements, :stock_item_id
    add_index :stock_movements, :order_id
    add_index :stock_movements, [:stock_item_id, :order_id]
    add_foreign_key :stock_movements, :stock_items
    add_foreign_key :stock_movements, :orders
    add_foreign_key :stock_movements, :users
  end
end
