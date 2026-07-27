module Notifications
  # Arma el texto del mensaje de WhatsApp para compartir un pedido,
  # reutilizando el mismo formato de fecha que ya usan las vistas de
  # pedidos (strftime "%d/%m/%Y").
  class OrderWhatsappMessage
    def initialize(order)
      @order = order
    end

    def to_s
      lines = [
        "Cliente: #{order.customer.name}",
        "Pedido: #{order.number}",
        "Entrega: #{order.delivery_date.strftime('%d/%m/%Y')}",
        "",
        *product_lines
      ]

      lines.join("\n")
    end

    private

    attr_reader :order

    def product_lines
      order.order_items.map { |item| "• #{item.product_name_snapshot} x#{item.quantity}" }
    end
  end
end
