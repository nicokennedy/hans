class CreateOrderItems < ActiveRecord::Migration[7.1]
  def change
    create_table :order_items do |t|
      t.references :order, null: false, foreign_key: true
      t.references :product, null: false, foreign_key: true
      t.string :product_name_snapshot
      t.string :category_name_snapshot
      t.integer :quantity
      t.integer :unit_price_cents_snapshot
      t.integer :unit_cost_cents_snapshot
      t.integer :line_revenue_cents
      t.integer :line_cost_cents

      t.timestamps
    end
  end
end
