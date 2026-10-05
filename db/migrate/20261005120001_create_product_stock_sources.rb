class CreateProductStockSources < ActiveRecord::Migration[7.1]
  def change
    create_table :product_stock_sources do |t|
      t.references :product, null: false, foreign_key: true
      t.references :preparation, null: false, foreign_key: true
      # Cuánto del objeto de stock descuenta UNA unidad vendida del producto,
      # expresado en la unidad de la preparación (ej. 1 un de tapas por alfajor).
      t.decimal :quantity, precision: 12, scale: 3, null: false, default: 1
      t.timestamps
    end

    add_index :product_stock_sources, [:product_id, :preparation_id], unique: true
  end
end
