module Retail
  # Stock de VENTA ONLINE de las variantes de la tienda (RetailProductVariant#stock_quantity). No tiene
  # nada que ver con el stock de producción/mayorista (Stock::DispatchReconciler, stock_items): no lo
  # lee ni lo modifica.
  #
  # Mecanismo de reserva: cada ítem de pedido que salió de una variante guarda cuántas unidades tiene
  # descontadas (online_stock_reserved). Reconciliar un pedido calcula cuántas DEBERÍA tener y aplica
  # solo la diferencia, con las variantes bloqueadas (SELECT ... FOR NO KEY UPDATE) en orden de id:
  #  - pedido vigente (pendiente de confirmación o confirmado, no cancelado): reserva su cantidad;
  #  - cancelado o rechazado: reserva 0 (devuelve lo descontado);
  #  - cambio de cantidad al editar: descuenta o devuelve la diferencia.
  # Como se aplica la diferencia contra lo ya reservado, repetir la operación (reintentos, cambios de
  # estado ida y vuelta, el mismo pedido reconciliado dos veces) nunca descuenta dos veces, y el
  # bloqueo de fila hace que dos compras simultáneas de la última unidad no puedan pasar las dos.
  #
  # FOR NO KEY UPDATE y no FOR UPDATE: insertar el ítem del pedido toma un bloqueo KEY SHARE sobre la
  # variante (por la clave foránea); FOR UPDATE choca con ese bloqueo y dos compras simultáneas se
  # trababan (deadlock). NO KEY UPDATE no choca con KEY SHARE pero sí entre compras, que es lo que
  # importa: la segunda espera y lee el stock ya descontado.
  #
  # Variantes sin límite (stock_quantity NULL) no reservan nada. Si una variante pasa de "sin límite"
  # a "limitado", los pedidos anteriores no se descuentan retroactivamente: el número cargado es lo que
  # queda para vender desde ese momento.
  class OnlineStock
    LOCK = "FOR NO KEY UPDATE"
    class Insufficient < StandardError
      attr_reader :variant, :available, :requested

      def initialize(variant, available, requested)
        @variant = variant
        @available = available
        @requested = requested
        super(message_for_customer)
      end

      def message_for_customer
        name = variant.full_name
        return "“#{name}” está agotado." if available <= 0

        "De “#{name}” #{available == 1 ? 'queda 1 unidad' : "quedan #{available} unidades"} (pediste #{requested})."
      end
    end

    # Debe llamarse dentro de la transacción que guarda el pedido o cambia su estado. Lanza
    # Insufficient si alguna variante limitada no alcanza (la transacción se deshace entera).
    def self.reconcile!(order)
      new(order).reconcile!
    end

    # Devuelve lo reservado por un ítem que se elimina (ver RetailOrderItem before_destroy).
    def self.release_item!(item)
      return if item.online_stock_reserved.to_i.zero? || item.retail_product_variant_id.nil?

      variant = RetailProductVariant.lock(LOCK).find_by(id: item.retail_product_variant_id)
      variant.update_columns(stock_quantity: variant.stock_quantity + item.online_stock_reserved, updated_at: Time.current) if variant&.limited_stock?
      item.update_columns(online_stock_reserved: 0) unless item.destroyed?
    end

    def initialize(order)
      @order = order
    end

    def reconcile!
      items = @order.retail_order_items.reload.where.not(retail_product_variant_id: nil).to_a
      return if items.empty?

      holds = holds_stock?
      variants = RetailProductVariant.where(id: items.map(&:retail_product_variant_id).uniq).order(:id).lock(LOCK).to_a.index_by(&:id)

      # Primero las devoluciones y después los descuentos, así un cambio de cantidad en el mismo
      # pedido nunca se rechaza por su propia reserva.
      plans = items.map do |item|
        variant = variants[item.retail_product_variant_id]
        target = holds && variant&.limited_stock? ? item.quantity : 0
        # Lo reservado se devuelve aunque la variante haya pasado a "sin límite" (no suma nada).
        [item, variant, target - item.online_stock_reserved.to_i]
      end

      plans.select { |_, _, delta| delta.negative? }.each { |item, variant, delta| apply(item, variant, delta) }
      plans.select { |_, _, delta| delta.positive? }.group_by { |_, variant, _| variant }.each do |variant, rows|
        wanted = rows.sum { |_, _, delta| delta }
        raise Insufficient.new(variant, variant.stock_quantity, rows.sum { |item, _, _| item.quantity }) if variant.stock_quantity < wanted

        rows.each { |item, _, delta| apply(item, variant, delta) }
      end
    end

    private

    # Reservan los pedidos vigentes de la tienda: no cancelados ni rechazados.
    def holds_stock?
      !@order.canceled? && !@order.confirmation_rejected?
    end

    def apply(item, variant, delta)
      if variant&.limited_stock?
        variant.stock_quantity -= delta
        variant.update_columns(stock_quantity: variant.stock_quantity, updated_at: Time.current)
      end
      item.update_columns(online_stock_reserved: item.online_stock_reserved.to_i + delta)
    end
  end
end
