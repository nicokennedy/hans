module OrdersHelper
  # Clase de badge según el estado de pago, para que el cliente distinga de
  # un vistazo si un pedido está pagado, parcial o pendiente. Reutiliza las
  # clases utilitarias de Bootstrap ya usadas en el proyecto (bg-success,
  # bg-warning, y su variante "subtle" para un amarillo más claro) en vez de
  # CSS inline o clases nuevas. No cubre "canceled" porque payment_status
  # no tiene ese valor hoy (solo pending/partial/paid).
  PAYMENT_STATUS_BADGE_CLASSES = {
    "paid" => "bg-success",
    "partial" => "bg-warning text-dark",
    "pending" => "bg-warning-subtle text-warning-emphasis"
  }.freeze

  def payment_status_badge_class(payment_status)
    PAYMENT_STATUS_BADGE_CLASSES[payment_status] || "bg-secondary"
  end

  # Campos ocultos con el contexto de navegación del listado (filtros y página), para
  # que los formularios del pedido (pagos, edición) lo devuelvan al guardar.
  def orders_context_hidden_fields
    safe_join(orders_context.map { |key, value| hidden_field_tag(key, value, id: nil) })
  end

  # "Volver" del pedido: a la cuenta corriente o a la ficha del cliente si se entró desde
  # Clientes (siempre del cliente del propio pedido); si no, al listado de Pedidos con sus filtros.
  def order_back_link(order)
    case customers_context.back_to
    when "account"
      link_to "← Cuenta corriente", admin_customer_account_path(order.customer, customers_context.account_query), class: "btn btn-outline-dark", id: "back-to-orders"
    when "customer"
      link_to "← Cliente", admin_customer_path(order.customer, customers_context.list_query), class: "btn btn-outline-dark", id: "back-to-orders"
    else
      link_to "← Volver", admin_orders_path(orders_list_context), class: "btn btn-outline-dark", id: "back-to-orders"
    end
  end
end
