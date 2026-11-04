module Collections
  # Resumen financiero de un listado de pedidos (mayoristas u Order, minoristas o RetailOrder):
  # recibe el scope YA filtrado y sin paginar, así el resumen cubre todos los pedidos que
  # cumplen los filtros y no solo los de la página visible. Solo lectura, en una consulta.
  #
  # Mismos criterios que el resumen de Clientes y la cuenta corriente (CustomerAccounts::Summary):
  #  - Pedidos cancelados: no cuentan en ningún indicador; se informa cuántos quedaron afuera.
  #  - Minoristas: solo cuentan los confirmados (RetailOrder.committed, el mismo criterio que
  #    producción y stock). Los pendientes de confirmación y los rechazados de la tienda online
  #    quedan afuera y se informan aparte. Los manuales nacen confirmados: no cambian.
  #  - Facturado = suma de total_cents.
  #  - Cobrado = suma de amount_paid_cents: la caché de los pagos vigentes imputados a cada
  #    pedido (pagos individuales y aplicaciones de pagos de cuenta corriente). Un pago de cuenta
  #    corriente cuenta solo por lo aplicado a estos pedidos; su saldo a favor sin aplicar no.
  #  - Pendiente = suma de los saldos positivos de cada pedido: un pedido con excedente no
  #    descuenta la deuda de otros, así que nunca es negativo.
  class OrdersSummary
    attr_reader :orders_count, :invoiced_cents, :collected_cents, :pending_cents, :canceled_count, :awaiting_count, :rejected_count

    def initialize(scope)
      scope = scope.unscope(:order, :limit, :offset, :includes, :preload, :eager_load)
      table = scope.klass.quoted_table_name
      billable = scope.where.not(status: "canceled")
      @awaiting_count = @rejected_count = 0
      if scope.klass.respond_to?(:committed)
        @awaiting_count = billable.where(confirmation_status: "awaiting").count
        @rejected_count = billable.where(confirmation_status: "rejected").count
        billable = billable.merge(scope.klass.committed)
      end

      totals = billable.pick(
        Arel.sql("COUNT(*)"),
        Arel.sql("COALESCE(SUM(#{table}.total_cents), 0)"),
        Arel.sql("COALESCE(SUM(#{table}.amount_paid_cents), 0)"),
        Arel.sql("COALESCE(SUM(GREATEST(#{table}.total_cents - #{table}.amount_paid_cents, 0)), 0)")
      )
      # Un scope vacío por definición (Model.none) no consulta y devuelve nil.
      @orders_count, @invoiced_cents, @collected_cents, @pending_cents = (totals || [0, 0, 0, 0]).map(&:to_i)
      @canceled_count = scope.where(status: "canceled").count
    end
  end
end
