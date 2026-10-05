class AddProductionBatchSizeToStockItems < ActiveRecord::Migration[7.1]
  def change
    # Opcional (NULL = sin lote informado: el panel sigue mostrando "PRODUCIR n").
    # Cantidad de unidades físicas que rinde UNA tanda completa; la carga
    # cocina/admin, nunca se infiere de las recetas.
    add_column :stock_items, :production_batch_size, :decimal, precision: 12, scale: 3
  end
end
