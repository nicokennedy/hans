class AddStockOnlyToPreparations < ActiveRecord::Migration[7.1]
  def change
    # false por default: ninguna Preparation existente cambia de comportamiento.
    # true = objeto operativo de stock (ej. "Tapas Alfajor Almendra"): se cuenta
    # en el freezer, no tiene receta ni costo y no puede usarse como componente.
    add_column :preparations, :stock_only, :boolean, null: false, default: false
  end
end
