module Finance
  # Resultado económico simplificado y flujo de caja de un período (el de Finance::Summary:
  # un mes, un año o un rango personalizado). Solo lectura. NO es un estado de resultados
  # contable: no considera costo de mercadería vendida ni variación de inventario.
  #
  # Criterios (centavos enteros, cada fecha con su propio significado):
  #
  # Ventas (devengado) — se reutiliza Collections::OrdersSummary, el mismo cálculo de los
  # resúmenes de Pedidos y Pedidos Minoristas, aplicado a los pedidos con delivery_date en
  # el período:
  #  - Mayoristas (Order): sin cancelados. Facturado = total_cents (ya neto de descuentos).
  #  - Minoristas (RetailOrder): solo confirmados (RetailOrder.committed), sin cancelados,
  #    pendientes de confirmación ni rechazados. Facturado = total_cents (incluye envío).
  #  - Pedidos sin fecha de entrega: no pueden existir (Order valida delivery_date y
  #    retail_orders.delivery_date es NOT NULL); si existieran, no caen en ningún período.
  #
  # Cobrado del período (caja) — por fecha REAL de pago, aunque el pedido sea de otro mes,
  # sin pagos anulados. Cada ingreso se cuenta UNA vez:
  #  - Mayoristas: pagos individuales (Payment sin customer_payment_id, por paid_at) + pagos
  #    de cuenta corriente (CustomerPayment, por paid_on, completos aunque tengan saldo a
  #    favor sin aplicar). Las aplicaciones de cuenta corriente a pedidos (Payment con
  #    customer_payment_id) NO suman: son reparto de un ingreso ya contado. Mismo criterio
  #    que CustomerAccounts::Summary#received_cents.
  #  - Minoristas: RetailOrderPayment vigentes, por paid_at.
  #
  # Pendiente al cierre — de los pedidos facturados en el período: total menos los pagos
  # vigentes con fecha hasta el último día del período, sumando solo saldos positivos
  # (igual que el pendiente de los resúmenes existentes). Usa el total ACTUAL de cada pedido
  # y considera inexistentes los pagos anulados después (se anulan por error de carga).
  #
  # Egresos — de Finance::Summary: compras y gastos por accrual_on; pagos por paid_on.
  # Los pagos del período se separan según a qué se imputaron (compras / gastos); lo que
  # todavía no se imputó es anticipo a proveedores. Si un anticipo se aplica después, ese
  # importe pasa a figurar como pago de compras o gastos en el período del pago original.
  class PeriodResult
    Sales = Struct.new(:orders_count, :invoiced_cents, :collected_cents, :pending_at_close_cents, :canceled_count, :unconfirmed_count, keyword_init: true)

    attr_reader :summary

    def initialize(summary)
      @summary = summary
    end

    def period
      summary.period
    end

    # true si el período todavía no terminó: el "pendiente al cierre" es el saldo a hoy.
    def open_period?
      period.last >= summary.today
    end

    # --- Ventas -----------------------------------------------------------------------------------

    def wholesale
      @wholesale ||= begin
        orders = Collections::OrdersSummary.new(Order.where(delivery_date: period))
        Sales.new(
          orders_count: orders.orders_count, invoiced_cents: orders.invoiced_cents, canceled_count: orders.canceled_count, unconfirmed_count: 0,
          collected_cents: Payment.active.individual.where(paid_at: time_range).sum(:amount_cents) + CustomerPayment.active.where(paid_on: period).sum(:amount_cents),
          pending_at_close_cents: pending_at_close(Order.not_canceled.where(delivery_date: period), "payments", "order_id", "orders", time_range.last)
        )
      end
    end

    def retail
      @retail ||= begin
        orders = Collections::OrdersSummary.new(RetailOrder.where(delivery_date: period))
        Sales.new(
          orders_count: orders.orders_count, invoiced_cents: orders.invoiced_cents, canceled_count: orders.canceled_count,
          unconfirmed_count: orders.awaiting_count + orders.rejected_count,
          collected_cents: RetailOrderPayment.active.where(paid_at: period).sum(:amount_cents),
          pending_at_close_cents: pending_at_close(RetailOrder.committed.where(delivery_date: period), "retail_order_payments", "retail_order_id", "retail_orders", period.last)
        )
      end
    end

    def sales_cents
      wholesale.invoiced_cents + retail.invoiced_cents
    end

    # --- Resultado económico simplificado ---------------------------------------------------------

    def purchases_cents
      @purchases_cents ||= summary.purchases_cents
    end

    def expenses_cents
      @expenses_cents ||= summary.expenses_cents
    end

    def costs_cents
      purchases_cents + expenses_cents
    end

    def result_cents
      sales_cents - costs_cents
    end

    # Resultado sobre ventas en %, o nil si no hubo ventas (no se divide por cero).
    def result_margin
      return nil if sales_cents.zero?

      (result_cents * 100.0 / sales_cents).round(1)
    end

    # --- Flujo de caja ----------------------------------------------------------------------------

    def collected_cents
      wholesale.collected_cents + retail.collected_cents
    end

    def paid_purchases_cents
      outgoing_split.fetch("Purchase", 0)
    end

    def paid_expenses_cents
      outgoing_split.fetch("Expense", 0)
    end

    # Pagado a proveedores en el período y todavía sin imputar a ninguna compra o gasto.
    def paid_advances_cents
      paid_cents - paid_purchases_cents - paid_expenses_cents
    end

    # Total pagado: el mismo "Pagado en el período" del resumen (cada pago una vez).
    def paid_cents
      @paid_cents ||= summary.paid_in_period_cents
    end

    def net_cash_cents
      collected_cents - paid_cents
    end

    private

    # Payment.paid_at es datetime: el período se toma en la zona horaria de la app.
    def time_range
      Time.zone.local(period.first.year, period.first.month, period.first.day).beginning_of_day..Time.zone.local(period.last.year, period.last.month, period.last.day).end_of_day
    end

    def pending_at_close(scope, payments_table, foreign_key, orders_table, close)
      paid_sql = ApplicationRecord.sanitize_sql_array([
        "COALESCE((SELECT SUM(p.amount_cents) FROM #{payments_table} p WHERE p.#{foreign_key} = #{orders_table}.id AND p.voided_at IS NULL AND p.paid_at <= ?), 0)", close
      ])
      scope.sum(Arel.sql("GREATEST(#{orders_table}.total_cents - #{paid_sql}, 0)")).to_i
    end

    def outgoing_split
      @outgoing_split ||= OutgoingPaymentApplication.active.joins(:obligation)
                                                    .where(outgoing_payment_id: OutgoingPayment.active.where(paid_on: period).select(:id))
                                                    .group("obligations.source_type").sum(:amount_cents)
    end
  end
end
