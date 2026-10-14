# Visibilidad de productos por cliente. Todo producto existente queda "all" (disponible para
# todos), así el catálogo actual no cambia. Solo agrega columnas y una tabla; no modifica datos.
class AddCustomerVisibilityToProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :products, :customer_visibility, :string, null: false, default: "all"
    add_index :products, :customer_visibility

    create_table :product_customer_accesses do |t|
      t.references :product, null: false, foreign_key: true
      t.references :customer, null: false, foreign_key: true
      t.timestamps
    end
    add_index :product_customer_accesses, [:product_id, :customer_id], unique: true, name: "index_product_customer_accesses_unique"

    # Excepción administrativa explícita y auditable: quién y cuándo autorizó cargar en un
    # pedido un producto no habilitado para ese cliente.
    add_reference :order_items, :restriction_override_by, foreign_key: { to_table: :users }, null: true
    add_column :order_items, :restriction_override_at, :datetime
  end
end
