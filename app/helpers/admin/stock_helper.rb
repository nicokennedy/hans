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

  # "1 TANDA" / "2 TANDAS"
  def stock_batches_label(batches)
    "#{batches} #{batches == 1 ? 'TANDA' : 'TANDAS'}"
  end

  # Cantidad con la que se pre-completa "+ Producción": la sugerida por tandas
  # si hay lote informado y falta producir; si no, vacío (como siempre).
  # Es solo un valor inicial editable — se puede registrar cualquier cantidad.
  def stock_suggested_quantity_value(snapshot)
    suggested = snapshot.production_suggested
    suggested&.positive? ? format_quantity(suggested) : nil
  end

  # "lote de 22 un" / "sin lote" — para el mensaje tras editar la configuración.
  def stock_batch_config_label(stock_item)
    batch = stock_item.production_batch_size
    batch ? "lote de #{format_quantity(batch)} #{stock_item.unit}" : "sin lote"
  end
end
