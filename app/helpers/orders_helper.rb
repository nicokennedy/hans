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
end
