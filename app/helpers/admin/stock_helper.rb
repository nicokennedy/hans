module Admin::StockHelper
  MOVEMENT_TYPE_LABELS = {
    "production" => "Producción",
    "dispatch" => "Salida por pedido",
    "adjustment" => "Ajuste de conteo"
  }.freeze

  STATUS_LABELS = {
    red: "🔴",
    orange: "🟠",
    green: "🟢"
  }.freeze

  STATUS_TEXT = {
    red: "PRODUCIR",
    orange: "STOCK JUSTO",
    green: "OK"
  }.freeze

  def stock_movement_type_label(movement_type)
    MOVEMENT_TYPE_LABELS[movement_type.to_s] || movement_type.to_s
  end

  def stock_status_emoji(status)
    STATUS_LABELS[status] || ""
  end

  def stock_status_text(status)
    STATUS_TEXT[status] || ""
  end
end
