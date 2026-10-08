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
end
