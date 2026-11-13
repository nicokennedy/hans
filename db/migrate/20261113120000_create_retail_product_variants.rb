# Variantes de los productos de la tienda minorista (tamaños de tortas, presentaciones de cajitas) y
# stock de venta online. Todo producto queda con al menos una variante: los existentes reciben una
# variante única con su precio actual, así nada cambia para ellos. El vínculo mayorista sigue en el
# producto (vale para todas sus variantes); una variante puede tener el suyo propio (ej. la mini).
#
# Stock online: stock_quantity NULL = sin límite (nunca un número ficticio); un número = unidades
# disponibles para vender por la tienda. Es independiente del stock de producción/mayorista
# (stock_items / stock_movements), que no se toca.
class CreateRetailProductVariants < ActiveRecord::Migration[7.1]
  def up
    create_table :retail_product_variants do |t|
      t.references :retail_product, null: false, foreign_key: { on_delete: :cascade }
      t.string :name # "18 cm", "Caja x 12". Vacío solo si es la única variante del producto.
      t.text :description # opcional: lo propio de esta variante (ej. condiciones de sabores de cada box)
      t.integer :position, null: false, default: 0 # de menor a mayor tamaño
      t.bigint :price_cents, null: false
      t.boolean :active, null: false, default: true
      t.integer :stock_quantity # NULL = sin límite
      t.references :product, foreign_key: { on_delete: :nullify } # producto mayorista propio de la variante (opcional)
      t.string :external_ref # trazabilidad de importaciones (ej. "takepedido:1yudkNrZCY591Wv3QFI4")
      t.timestamps
    end
    add_index :retail_product_variants, "retail_product_id, lower(coalesce(name, ''))", unique: true, name: "index_retail_product_variants_on_product_and_name"
    add_index :retail_product_variants, :external_ref, unique: true, where: "external_ref IS NOT NULL"
    add_check_constraint :retail_product_variants, "price_cents >= 0", name: "retail_product_variants_price_non_negative"
    add_check_constraint :retail_product_variants, "stock_quantity IS NULL OR stock_quantity >= 0", name: "retail_product_variants_stock_non_negative"

    change_table :retail_order_items do |t|
      t.references :retail_product_variant, foreign_key: { on_delete: :nullify }
      t.string :variant_name_snapshot
      # Unidades de esta línea descontadas del stock online de la variante (0 si no hay reserva).
      t.integer :online_stock_reserved, null: false, default: 0
    end
    add_check_constraint :retail_order_items, "online_stock_reserved >= 0", name: "retail_order_items_reserved_non_negative"

    execute <<~SQL
      INSERT INTO retail_product_variants (retail_product_id, name, position, price_cents, active, stock_quantity, created_at, updated_at)
      SELECT id, NULL, 1, price_cents, TRUE, NULL, NOW(), NOW() FROM retail_products
    SQL
  end

  def down
    remove_check_constraint :retail_order_items, name: "retail_order_items_reserved_non_negative"
    change_table :retail_order_items do |t|
      t.remove_references :retail_product_variant, foreign_key: true
      t.remove :variant_name_snapshot, :online_stock_reserved
    end
    drop_table :retail_product_variants
  end
end
