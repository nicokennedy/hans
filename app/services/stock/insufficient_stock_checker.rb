require "bigdecimal"

module Stock
  # Valida, para un Order a punto de guardarse, si alguno de sus StockItem
  # afectados (a través de productos configurados "solo vender si hay
  # stock") se queda sin cubrir. Devuelve mensajes de error listos para
  # agregar a errors[:base] — no valida nada si el pedido no toca ningún
  # producto con esa configuración, así que para el 100% de los productos
  # actuales (sell_without_stock: true por default) esto es un no-op.
  #
  # Toma un lock de fila sobre los StockItem involucrados (en orden de id,
  # para no generar deadlocks con otra validación concurrente) ANTES de
  # calcular disponible — como Order#save envuelve las validaciones en una
  # transacción, esto serializa dos pedidos simultáneos compitiendo por el
  # mismo último stock: el segundo espera, y cuando le toca ya ve reflejada
  # la reserva del primero.
  class InsufficientStockChecker
    def self.violations_for(order)
      new(order).violations
    end

    def initialize(order)
      @order = order
    end

    def violations
      return [] if relevant_order_items.empty?
      return [] if strict_product_ids.empty?

      demand = Stock::Demand.for_order_items(relevant_order_items)
      return [] if demand.empty?

      strict_stock_item_ids = Stock::Demand.for_order_items(strict_order_items).keys.map(&:id)
      return [] if strict_stock_item_ids.empty?

      # El lock solo tiene efecto real porque esto corre dentro de la
      # transacción que ya envuelve Order#save (validaciones incluidas).
      locked_items = StockItem.where(id: demand.keys.map(&:id)).order(:id).lock.to_a
      availability_by_id = Stock::Availability.new.for_items(locked_items).index_by { |snapshot| snapshot.stock_item.id }

      locked_items.filter_map do |stock_item|
        next unless strict_stock_item_ids.include?(stock_item.id)
        # Un pedido anterior al inicio del control no compite por este stock.
        next if order.delivery_date.present? && order.delivery_date < stock_item.stock_tracking_started_on

        snapshot = availability_by_id[stock_item.id]
        needed = demand[stock_item] || BigDecimal(0)
        remaining = snapshot.available_quantity - needed
        next if remaining >= 0

        "No hay stock suficiente de \"#{snapshot.name}\" para completar el pedido (disponible: #{format_quantity(snapshot.available_quantity)} #{snapshot.unit})."
      end
    end

    private

    attr_reader :order

    def relevant_order_items
      @relevant_order_items ||= order.order_items.reject(&:marked_for_destruction?).select { |item| item.product.present? }
    end

    def strict_product_ids
      @strict_product_ids ||= relevant_order_items
        .reject { |item| item.product.sell_without_stock? }
        .map(&:product_id)
        .uniq
    end

    def strict_order_items
      relevant_order_items.select { |item| strict_product_ids.include?(item.product_id) }
    end

    def format_quantity(value)
      value.to_d.to_s("F").sub(/0+\z/, "").sub(/\.\z/, "")
    end
  end
end
