# Notifica en tiempo real la creación de pedidos nuevos a sesiones admin y
# producción. Un solo stream global (no hay datos por-pedido que filtrar
# por destinatario: admin y producción ya ven la misma pantalla de pedido).
# Clientes y usuarios anónimos son rechazados explícitamente — reutiliza
# User#admin_or_production?, no crea un sistema de permisos paralelo.
class OrdersChannel < ApplicationCable::Channel
  STREAM_NAME = "orders_channel"

  def subscribed
    if current_user&.admin_or_production?
      stream_from STREAM_NAME
    else
      reject
    end
  end

  def self.broadcast_order_created(payload)
    ActionCable.server.broadcast(STREAM_NAME, payload.merge(type: "order_created"))
  end
end
