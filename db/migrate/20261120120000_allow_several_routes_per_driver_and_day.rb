# Repartos: un repartidor puede tener varios recorridos el mismo día (por ejemplo, sale con 6
# pedidos, vuelve a HANS y sale de nuevo con otros 4). Cada recorrido sigue siendo independiente
# (sus paradas, estado, historial y, más adelante, su rendición).
#  - Reemplaza el índice único (fecha, repartidor) por uno común: deja de limitar a uno por día.
#  - creation_token: identificador único del formulario "Crear nuevo reparto". Si llega dos
#    veces (doble clic, reintento), el segundo pedido devuelve el recorrido ya creado.
# No modifica filas existentes: solo índices y una columna nueva vacía.
class AllowSeveralRoutesPerDriverAndDay < ActiveRecord::Migration[7.1]
  def up
    remove_index :delivery_routes, name: "index_delivery_routes_on_date_and_driver"
    add_index :delivery_routes, [:date, :driver_id], name: "index_delivery_routes_on_date_and_driver"
    add_column :delivery_routes, :creation_token, :string
    add_index :delivery_routes, :creation_token, unique: true, where: "creation_token IS NOT NULL",
                                                 name: "index_delivery_routes_on_creation_token"
  end

  def down
    remove_index :delivery_routes, name: "index_delivery_routes_on_creation_token"
    remove_column :delivery_routes, :creation_token
    remove_index :delivery_routes, name: "index_delivery_routes_on_date_and_driver"
    add_index :delivery_routes, [:date, :driver_id], unique: true, where: "driver_id IS NOT NULL",
                                                     name: "index_delivery_routes_on_date_and_driver"
  end
end
