class AddSellWithoutStockToProducts < ActiveRecord::Migration[7.1]
  def change
    # true por default: todos los productos existentes siguen vendiéndose
    # exactamente igual que hoy (sin ninguna restricción de stock) hasta
    # que un admin lo desactive explícitamente para un producto puntual.
    add_column :products, :sell_without_stock, :boolean, null: false, default: true
  end
end
