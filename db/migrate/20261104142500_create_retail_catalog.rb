# Etapa 2 de la tienda online: catálogo minorista propio, independiente del mayorista.
#
# - retail_categories: categorías administrables desde HANS (nada fijo en código).
# - retail_products: nombre, descripción, precio minorista propio (centavos), categoría, estado,
#   destacado, orden e identificador interno único (code). product_id vincula opcionalmente con un
#   producto mayorista (para producción en la etapa del checkout); si ese producto se borra, el
#   vínculo se limpia solo (on_delete: :nullify) sin tocar el producto minorista.
# - retail_product_photos: varias fotos por producto, una principal (índice único parcial), con
#   orden y checksum para no repetir la misma imagen en un producto. El archivo vive en Active
#   Storage (Cloudflare R2 en producción), nunca en PostgreSQL.
#
# Solo crea tablas nuevas: no modifica ni borra datos existentes.
class CreateRetailCatalog < ActiveRecord::Migration[7.1]
  def change
    create_table :retail_categories do |t|
      t.string :name, null: false
      t.boolean :active, null: false, default: true
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :retail_categories, "lower(name)", unique: true, name: "index_retail_categories_on_lower_name"

    create_table :retail_products do |t|
      t.string :name, null: false
      t.string :code, null: false
      t.text :description
      t.bigint :price_cents, null: false
      t.references :retail_category, null: false, foreign_key: { on_delete: :restrict }
      t.references :product, foreign_key: { on_delete: :nullify }
      t.boolean :active, null: false, default: false
      t.boolean :featured, null: false, default: false
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :retail_products, "lower(code)", unique: true, name: "index_retail_products_on_lower_code"
    add_index :retail_products, [:active, :position]
    add_check_constraint :retail_products, "price_cents >= 0", name: "retail_products_price_non_negative"

    create_table :retail_product_photos do |t|
      t.references :retail_product, null: false, foreign_key: { on_delete: :cascade }
      t.boolean :primary, null: false, default: false
      t.integer :position, null: false, default: 0
      t.string :checksum, null: false
      t.timestamps
    end
    add_index :retail_product_photos, :retail_product_id, unique: true, where: '"primary"', name: "index_retail_product_photos_one_primary"
    add_index :retail_product_photos, [:retail_product_id, :checksum], unique: true, name: "index_retail_product_photos_unique_checksum"
  end
end
