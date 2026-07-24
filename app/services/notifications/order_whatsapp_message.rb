module Notifications
  # Arma el texto del mensaje de WhatsApp para avisar de un pedido nuevo,
  # reutilizando el mismo formato de fecha/moneda que ya usan las vistas de
  # pedidos (strftime "%d/%m/%Y" y number_with_delimiter).
  class OrderWhatsappMessage
    include ActionView::Helpers::NumberHelper

    def initialize(order, admin_order_url)
      @order = order
      @admin_order_url = admin_order_url
    end

    def to_s
      lines = [
        "🟢 Nuevo pedido recibido",
        "Pedido: #{order.number}",
        "Cliente: #{order.customer.name}",
        "Entrega: #{order.delivery_date.strftime('%d/%m/%Y')}",
        *product_lines,
        "Total: $#{number_with_delimiter(order.total_cents / 100)}",
        "Ver pedido: #{admin_order_url}"
      ]

      lines.join("\n")
    end

    private

    attr_reader :order, :admin_order_url

    def product_lines
      order.order_items.map { |item| "• #{item.product_name_snapshot} x#{item.quantity}" }
    end
  end
end
