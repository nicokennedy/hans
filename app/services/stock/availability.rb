require "bigdecimal"

module Stock
  # Arma la foto completa de un StockItem (o de todos los activos, para el
  # panel) combinando el ledger (físico) con la demanda en vivo (comprometido
  # futuro / salidas de hoy). Corre la conciliación de pendientes como
  # primer paso — red de seguridad para que "físico" nunca esté atrasado
  # solo porque nadie entró antes a esta pantalla (ver Stock::DispatchReconciler).
  class Availability
    Snapshot = Struct.new(
      :stock_item, :name, :unit,
      :physical_quantity, :future_committed, :today_dispatch, :today_dispatch_materialized,
      :available_quantity, :minimum_quantity, :production_needed, :status,
      :production_batch_size, :production_batches_needed, :production_suggested,
      keyword_init: true
    )

    def self.dashboard(now: Time.current)
      new(now: now).dashboard
    end

    def self.for_item(stock_item, now: Time.current)
      new(now: now).for_item(stock_item)
    end

    def initialize(now: Time.current)
      @now = now
    end

    def dashboard
      sort_snapshots(for_items(StockItem.active.includes(:stockable).to_a))
    end

    def for_item(stock_item)
      for_items([ stock_item ]).first
    end

    # Corre la conciliación de pendientes UNA sola vez (no una vez por
    # ítem) y arma la foto de todos los StockItem pedidos en la misma
    # pasada — usado tanto por el panel (todos los activos) como por
    # Stock::InsufficientStockChecker (un subconjunto puntual).
    def for_items(stock_items)
      Stock::DispatchReconciler.reconcile_due!(now: now)
      # reconcile_due! puede haber actualizado quantity de alguno de estos
      # ítems a través de OTRA instancia (la que arma internamente al
      # recorrer los pedidos vencidos) — recargar acá es necesario para que
      # "físico" refleje lo que se acaba de materializar en esta misma
      # llamada, no un valor en memoria desactualizado.
      stock_items.each(&:reload)

      future_demand = Stock::Demand.for_order_items(future_order_items)
      today_demand = Stock::Demand.for_order_items(today_order_items)

      stock_items.map { |item| build_snapshot(item, future_demand, today_demand) }
    end

    private

    attr_reader :now

    # "hoy" se deriva de now (el mismo now: que se le pasa a este servicio),
    # nunca de Date.current directamente — mismo criterio que
    # Stock::DispatchReconciler, para que ambos coincidan siempre incluso
    # si se les pasa un now: explícito sin travel_to.
    def today
      now.in_time_zone.to_date
    end

    def future_order_items
      OrderItem.joins(:order).merge(Order.not_canceled.where("orders.delivery_date > ?", today))
    end

    def today_order_items
      OrderItem.joins(:order).merge(Order.not_canceled.where(orders: { delivery_date: today }))
    end

    def build_snapshot(stock_item, future_demand, today_demand)
      cutoff_passed = Stock::DispatchReconciler.cutoff_passed?(now: now)

      future = future_demand[stock_item] || BigDecimal(0)
      today = today_demand[stock_item] || BigDecimal(0)
      physical = stock_item.quantity.to_d
      # Antes de las 13:00, las salidas de hoy todavía no están en el
      # físico -> hay que restarlas para saber cuánto queda disponible.
      # Después de las 13:00 ya están materializadas EN el físico (las
      # reconcilió DispatchReconciler.reconcile_due! arriba) -> restarlas
      # de nuevo sería doble descuento.
      pending_today = cutoff_passed ? BigDecimal(0) : today
      available = physical - future - pending_today
      minimum = stock_item.minimum_quantity.to_d
      production_needed = [ minimum - available, BigDecimal(0) ].max
      batch_size = stock_item.production_batch_size&.to_d
      batches_needed = batches_for(production_needed, batch_size)

      Snapshot.new(
        stock_item: stock_item,
        name: stock_item.name,
        unit: stock_item.unit,
        physical_quantity: physical,
        future_committed: future,
        today_dispatch: today,
        today_dispatch_materialized: cutoff_passed,
        available_quantity: available,
        minimum_quantity: minimum,
        production_needed: production_needed,
        status: status_for(available, minimum),
        production_batch_size: batch_size,
        production_batches_needed: batches_needed,
        production_suggested: batches_needed && batches_needed * batch_size
      )
    end

    # Cuántas tandas completas hacen falta para cubrir el faltante. Sin lote
    # informado no hay sugerencia de tandas (nil): el panel muestra
    # "PRODUCIR n" como siempre. production_needed ya contempla físico,
    # salidas, compromisos y mínimo — acá solo se redondea hacia arriba a
    # tandas, no se recalcula nada.
    def batches_for(production_needed, batch_size)
      return nil if batch_size.nil?
      return 0 unless production_needed.positive?

      (production_needed / batch_size).ceil
    end

    def status_for(available, minimum)
      return :red if available < minimum
      return :orange if available <= minimum * BigDecimal("1.2")

      :green
    end

    def sort_snapshots(snapshots)
      priority = { red: 0, orange: 1, green: 2 }
      snapshots.sort_by { |snapshot| [ priority.fetch(snapshot.status), -snapshot.production_needed ] }
    end
  end
end
