module Notifications
  # Punto único de disparo para "se creó un pedido nuevo": arma un payload
  # sin datos sensibles, lo transmite por Action Cable a las sesiones
  # admin/producción abiertas, y encola el envío de Web Push. Se llama una
  # sola vez desde Order#notify_order_created (after_create_commit), así que
  # funciona igual sin importar si el pedido se creó desde el checkout del
  # cliente o desde el alta de admin.
  class OrderCreatedBroadcaster
    def self.call(order)
      new(order).call
    end

    def initialize(order)
      @order = order
    end

    def call
      OrdersChannel.broadcast_order_created(payload)
      PushNotificationJob.perform_later(order.id)
    end

    private

    attr_reader :order

    # Solo lo mínimo para mostrar el aviso y navegar al pedido. Nunca
    # cost_cents, márgenes, medios de pago, ni datos de otros pedidos.
    def payload
      {
        order_id: order.id,
        order_number: order.number,
        customer_name: order.customer.name,
        created_at: order.created_at.iso8601,
        url: Rails.application.routes.url_helpers.admin_order_path(order)
      }
    end
  end
end
