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

  HISTORY_KIND_LABELS = {
    "production" => "Producción",
    "sale" => "Venta",
    "adjustment" => "Ajuste manual",
    "correction" => "Cancelación / corrección de pedido"
  }.freeze

  HISTORY_FILTER_LABELS = {
    "all" => "Todos",
    "production" => "Producción",
    "sale" => "Ventas",
    "adjustment" => "Ajustes",
    "correction" => "Cancelaciones / correcciones"
  }.freeze

  def stock_history_kind_label(kind)
    HISTORY_KIND_LABELS[kind.to_s] || kind.to_s
  end

  def stock_history_filter_label(filter)
    HISTORY_FILTER_LABELS[filter.to_s] || filter.to_s
  end

  # "+10 un" / "-4 un": verde si ingresa, rojo si egresa (ver .stock-move en application.scss).
  def stock_history_quantity(movement, unit)
    sign = movement.quantity.positive? ? "+" : "-"
    "#{sign}#{format_quantity(movement.quantity.abs)} #{unit}"
  end

  def stock_history_tone(movement)
    movement.quantity.positive? ? "in" : "out"
  end

  # Fecha y hora en Argentina (config.time_zone): "08/10/2026 - 09:35".
  def stock_history_time(time)
    time.in_time_zone("America/Argentina/Buenos_Aires").strftime("%d/%m/%Y - %H:%M")
  end

  # Quién hizo el movimiento. Los movimientos anteriores a este historial pueden
  # no tener usuario: se muestra tal cual, sin asignar ninguno. Las salidas por
  # pedidos las genera el sistema (conciliación automática), no una persona.
  def stock_history_user_label(entry)
    return entry.user.email if entry.user
    return nil if entry.kind.in?(%w[sale correction])

    "Usuario no registrado"
  end

  # Link que conserva los filtros actuales y cambia solo lo indicado.
  def stock_history_path(stock_item, history, overrides = {})
    query = {
      kind: (history.filter unless history.filter == "all"),
      from: history.from&.iso8601,
      to: history.to&.iso8601
    }.merge(overrides)

    admin_stock_item_path(stock_item, query.compact_blank)
  end
end
