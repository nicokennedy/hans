require "bigdecimal"

module Stock
  # Convierte pedidos vencidos en movimiento físico real, por diferencia
  # (delta) contra lo que YA se registró — nunca "un solo movimiento al
  # entregar". Ver la explicación completa acordada con el negocio:
  #
  #   objetivo (cuánto DEBERÍA haber salido a esta altura, para este pedido
  #   y este StockItem):
  #     0                    si el pedido está canceled
  #     0                    si delivery_date > hoy (todavía no vence)
  #     0                    si delivery_date == hoy y todavía no son las
  #                          13:00 hora local (corte diario de stock)
  #     consumo actual       si delivery_date < hoy, o si delivery_date ==
  #                          hoy y ya pasaron las 13:00
  #
  #   delta = -objetivo - (suma de movimientos "dispatch" ya registrados
  #                        para este StockItem+Order)
  #
  # Si delta != 0 se crea UN movimiento por ese delta y listo — nunca hace
  # falta "deshacer" nada a mano. Esto cubre, con la MISMA fórmula, tanto la
  # primera salida como cualquier corrección posterior (cantidad editada,
  # producto reemplazado, pedido cancelado después de vencido, o la fecha
  # de entrega cambiada hacia adelante o atrás) — nunca duplica ni pierde
  # un movimiento, porque siempre compara contra lo que el ledger dice que
  # ya pasó, nunca contra "si ya se procesó antes".
  class DispatchReconciler
    CUTOFF_HOUR = 13

    def self.call(order, now: Time.current)
      new(order, now: now).call
    end

    # Red de seguridad para el simple paso del tiempo: reconcilia todos los
    # pedidos que podrían tener un delta pendiente, sin depender de que
    # alguien haya tocado ese pedido puntual. Un pedido individual roto no
    # bloquea al resto (mismo criterio que Costing::RecalculateAllRecipeProducts).
    def self.reconcile_due!(now: Time.current)
      reconciled = 0
      errors = []

      candidate_orders(now: now).find_each do |order|
        begin
          call(order, now: now)
          reconciled += 1
        rescue => e
          errors << "Order##{order.id}: #{e.class}: #{e.message}"
        end
      end

      Result.new(reconciled: reconciled, errors: errors)
    end

    # "today" siempre se deriva de now, nunca de Date.current directamente
    # (que solo refleja travel_to/el reloj real) — así el mismo now: que se
    # pasa explícitamente gobierna TODA la lógica de una sola vez, sin
    # depender de que quien llama también haya envuelto todo en travel_to.
    def self.cutoff_passed?(now: Time.current)
      now = now.in_time_zone
      now >= now.to_date.in_time_zone.change(hour: CUTOFF_HOUR, min: 0, sec: 0)
    end

    Result = Struct.new(:reconciled, :errors, keyword_init: true)

    def self.candidate_orders(now: Time.current)
      today = now.in_time_zone.to_date
      # Nada anterior a la fecha de inicio del control más temprana puede
      # generar una salida, así que ni se recorre (evita revisar toda la
      # historia de pedidos en cada carga del panel).
      earliest_start = StockItem.active.minimum(:stock_tracking_started_on)
      due = Order.none
      if earliest_start
        due = Order.not_canceled.where("delivery_date >= ? AND delivery_date < ?", earliest_start, today)
        due = due.or(Order.not_canceled.where(delivery_date: today)) if cutoff_passed?(now: now) && today >= earliest_start
      end

      # Además de lo vencido, cualquier pedido que YA tenga movimientos de
      # salida registrados — para poder revertirlos si se canceló o si su
      # fecha se movió hacia adelante después de haber sido materializado.
      ids_with_existing_dispatch = StockMovement.dispatch.distinct.pluck(:order_id).compact
      Order.where(id: due.pluck(:id) | ids_with_existing_dispatch)
    end

    def initialize(order, now: Time.current)
      @order = order
      @now = now
    end

    def call
      relevant_stock_items.each { |stock_item| reconcile_one(stock_item) }
    end

    private

    attr_reader :order, :now

    def relevant_stock_items
      current_demand.keys | stock_items_with_existing_dispatch_movements
    end

    def current_demand
      @current_demand ||= Stock::Demand.for_order_items(order.order_items.includes(:product))
    end

    def stock_items_with_existing_dispatch_movements
      StockItem.where(id: StockMovement.dispatch.where(order: order).select(:stock_item_id)).to_a
    end

    def reconcile_one(stock_item)
      target_signed = -objetivo_magnitude(stock_item)
      already_signed = StockMovement.dispatch.where(stock_item: stock_item, order: order).sum(:quantity)
      delta = target_signed - already_signed
      return if delta.zero?

      stock_item.apply_movement!(movement_type: :dispatch, quantity: delta, order: order)
    end

    def objetivo_magnitude(stock_item)
      today = now.in_time_zone.to_date

      return BigDecimal(0) if order.canceled?
      return BigDecimal(0) if order.delivery_date.nil?
      # Antes de la fecha de inicio del control de este ítem: no cuenta.
      return BigDecimal(0) if order.delivery_date < stock_item.stock_tracking_started_on
      return BigDecimal(0) if order.delivery_date > today
      return BigDecimal(0) if order.delivery_date == today && !self.class.cutoff_passed?(now: now)

      current_demand[stock_item] || BigDecimal(0)
    end
  end
end
