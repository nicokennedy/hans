# Etapa 2 del rediseño 2026: cajas con contenido personalizable (ver docs/TIENDA_MINORISTA.md).
#
# Solo agrega (no destructiva):
#  - retail_products.customizable_content: "Permitir personalizar el contenido" (falso por defecto,
#    así ningún producto existente cambia).
#  - retail_product_variants.content_units: unidades EXACTAS que lleva la caja de esa variante
#    (1 a 200). Explícito: nunca se deduce del nombre ("Caja x 24").
#  - retail_product_flavors: sabores del producto (valen para todas sus variantes), con orden y
#    disponibilidad manual.
#  - retail_order_items.composition: copia fija de la composición elegida
#    {"units": 24, "flavors": [{"id": 1, "name": "Almendra", "quantity": 12}, ...]}. Los pedidos
#    existentes quedan en NULL y no cambian.
class AddCustomizableContentToRetailProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :retail_products, :customizable_content, :boolean, default: false, null: false

    add_column :retail_product_variants, :content_units, :integer
    add_check_constraint :retail_product_variants, "content_units IS NULL OR (content_units >= 1 AND content_units <= 200)",
      name: "retail_product_variants_content_units_range"

    create_table :retail_product_flavors do |t|
      t.references :retail_product, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.integer :position, default: 0, null: false
      t.boolean :active, default: true, null: false
      t.timestamps
    end
    add_index :retail_product_flavors, "retail_product_id, lower(name)", unique: true, name: "index_retail_product_flavors_on_product_and_name"

    add_column :retail_order_items, :composition, :jsonb
  end
end
