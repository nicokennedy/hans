module DeliveryRoutes
  # Rendición de UN recorrido (R4), calculada siempre desde los registros: nunca se edita a mano.
  #
  #   efectivo a entregar = cobros vigentes − gastos vigentes
  #
  # Cobro vigente: no corregido y con su CustomerPayment sin anular (si administración lo anuló
  # desde la cuenta corriente, deja de contar y se avisa). Si los gastos superan los cobros
  # (solo posible con una excepción de administración), el efectivo a entregar es $0 y la
  # diferencia queda como "importe pendiente de resolver" (no es efectivo negativo).
  class Settlement
    attr_reader :route

    def initialize(route)
      @route = route
    end

    def collections
      @collections ||= route.collections.includes(:customer, :customer_payment, :created_by, :voided_by, delivery_stop: :order).to_a
    end

    def counted_collections
      collections.select(&:counts?)
    end

    def unidentified_collections
      counted_collections.select(&:unidentified?)
    end

    def voided_outside_collections
      collections.select(&:voided_outside?)
    end

    def expenses
      @expenses ||= route.expenses.includes(:created_by, :voided_by, :expense).to_a
    end

    def counted_expenses
      expenses.reject(&:voided?)
    end

    def collected_cents
      counted_collections.sum(&:amount_cents)
    end

    def expenses_cents
      counted_expenses.sum(&:amount_cents)
    end

    def incomes
      @incomes ||= route.incomes.includes(:created_by, :voided_by, evidence_attachment: :blob).to_a
    end

    def other_income_cents
      incomes.reject(&:voided?).sum(&:amount_cents)
    end

    def expected_cents
      collected_cents + other_income_cents - expenses_cents
    end

    # Lo que el repartidor tiene que entregar (nunca negativo).
    def to_deliver_cents
      [expected_cents, 0].max
    end

    # Gastos por encima de lo cobrado (excepción de administración): queda pendiente de resolver.
    def unresolved_cents
      [-expected_cents, 0].max
    end

    # Efectivo que todavía puede usar para gastos.
    def available_cents
      to_deliver_cents
    end

    def stops
      @stops ||= route.active_stops.includes(:photos, order: :customer).to_a
    end

    def pending_stops
      stops.select { |stop| stop.delivery_status == "pending" }
    end

    def pending_photo_stops
      stops.select(&:receipt_photo_pending?)
    end

    def unpaid_stops
      stops.select { |stop| stop.order? && stop.delivery_status == "delivered" && stop.balance_due_cents.positive? }
    end
  end
end
