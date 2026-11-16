# Portada configurable de la tienda pública: título, subtítulo, texto alternativo y encuadre de la
# foto de portada (la foto vive en Active Storage, como las del catálogo: has_one_attached :hero_image).
class AddHeroToRetailStoreSettings < ActiveRecord::Migration[7.1]
  def change
    add_column :retail_store_settings, :hero_title, :string
    add_column :retail_store_settings, :hero_subtitle, :text
    add_column :retail_store_settings, :hero_image_alt, :string
    add_column :retail_store_settings, :hero_image_position, :string, null: false, default: "center"
  end
end
