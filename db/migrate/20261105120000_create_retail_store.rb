# Etapa 4 de la tienda online: tienda pública, carrito y checkout por WhatsApp.
#
# - retail_store_settings: una sola fila con la publicación de la tienda (nace CERRADA: solo los
#   administradores la ven, en vista previa), el WhatsApp de HANS al que se dirige el mensaje del
#   pedido y los datos para transferencia (vacíos: no se inventan, los carga el equipo).
# - retail_orders.buyer_email: email del comprador (la tienda lo pide; opcional en pedidos manuales).
# - retail_order_items.retail_product_id: de qué producto de la tienda salió cada ítem. Opcional;
#   si el producto minorista se borra, el ítem conserva su nombre, cantidad y precio (nullify).
#
# Solo agrega: no modifica ni borra datos existentes (los pedidos anteriores quedan sin email y
# sus ítems sin producto de la tienda).
class CreateRetailStore < ActiveRecord::Migration[7.1]
  def up
    create_table :retail_store_settings do |t|
      t.boolean :published, null: false, default: false
      t.datetime :published_at
      t.string :whatsapp_number, null: false
      t.text :bank_transfer_details
      t.references :updated_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end
    add_check_constraint :retail_store_settings, "whatsapp_number ~ '^[0-9]{10,15}$'", name: "retail_store_settings_whatsapp_digits"

    execute <<~SQL
      INSERT INTO retail_store_settings (published, whatsapp_number, created_at, updated_at)
      VALUES (false, '5492235275412', NOW(), NOW())
    SQL

    add_column :retail_orders, :buyer_email, :string
    add_reference :retail_order_items, :retail_product, foreign_key: { on_delete: :nullify }
  end

  def down
    remove_reference :retail_order_items, :retail_product, foreign_key: true
    remove_column :retail_orders, :buyer_email
    drop_table :retail_store_settings
  end
end
