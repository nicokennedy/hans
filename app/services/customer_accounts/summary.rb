module CustomerAccounts
  # Estado de cuenta de un cliente. NO tiene una contabilidad propia: todo sale de los
  # mismos saldos que ya usa el resto de HANS (Order#total_cents, Order#amount_paid_cents
  # y sus Payment) más los pagos de cuenta corriente.
  #
  # Reglas (todas con centavos enteros):
  #  - Pedidos cancelados: no son deuda exigible ni se cuentan como facturado. Lo que ya
  #    se hubiera pagado sobre ellos no se mueve solo: se informa aparte (canceled_paid_cents).
  #  - Saldo pendiente = suma de los saldos positivos de los pedidos no cancelados.
  #  - Un pedido cuyo total bajó por debajo de lo pagado queda con saldo negativo: no se
  #    ajusta nada solo; se informa como "excedente" para revisarlo.
  #  - Saldo a favor = lo no aplicado de los pagos de cuenta corriente vigentes.
  #  - Ingresos reales = pagos individuales + pagos de cuenta corriente (cada transferencia
  #    UNA vez); las aplicaciones a pedidos NO suman ingresos.
  class Summary
    FILTERS = %w[all pending paid].freeze
    HISTORY_LIMIT = 200

    attr_reader :customer, :filter, :from, :to

    def initialize(customer, filter: nil, from: nil, to: nil)
      @customer = customer
      @filter = FILTERS.include?(filter.to_s) ? filter.to_s : "all"
      @from = parse_date(from)
      @to = parse_date(to)
    end

    def invalid_dates?
      @invalid_dates == true
    end

    def billable_orders
      customer.orders.not_canceled
    end

    def orders_count
      billable_orders.count
    end

    def canceled_orders_count
      customer.orders.canceled.count
    end

    def invoiced_cents
      billable_orders.sum(:total_cents)
    end

    # Pagos aplicados a los pedidos no cancelados (lo que ya descuenta de la deuda).
    def applied_cents
      billable_orders.sum(:amount_paid_cents)
    end

    def pending_cents
      billable_orders.where("orders.total_cents > orders.amount_paid_cents").sum("orders.total_cents - orders.amount_paid_cents")
    end

    def overpaid_cents
      billable_orders.where("orders.amount_paid_cents > orders.total_cents").sum("orders.amount_paid_cents - orders.total_cents")
    end

    def canceled_paid_cents
      customer.orders.canceled.sum(:amount_paid_cents)
    end

    def credit_cents
      ApplyCredit.available_cents(customer)
    end

    # Ingreso real: cada pago individual una vez + cada pago de cuenta corriente una vez.
    def received_cents
      individual = Payment.active.individual.joins(:order).where(orders: { customer_id: customer.id }).sum(:amount_cents)
      individual + customer.customer_payments.active.sum(:amount_cents)
    end

    # Saldo de la cuenta corriente: deuda de los pedidos menos el crédito sin aplicar.
    def account_balance_cents
      pending_cents - credit_cents
    end

    def filtered_orders
      scope = billable_orders
      scope = scope.where("orders.total_cents > orders.amount_paid_cents") if filter == "pending"
      scope = scope.where(payment_status: "paid") if filter == "paid"
      scope = scope.where("orders.delivery_date >= ?", from) if from
      scope = scope.where("orders.delivery_date <= ?", to) if to
      scope.order(:delivery_date, :created_at, :id)
    end

    def pending_orders
      Distribution.pending_orders(customer)
    end

    # Historial: cada pago individual y cada pago de cuenta corriente UNA sola vez
    # (las aplicaciones de un pago de cuenta corriente se muestran adentro de él, no
    # como pagos aparte), del más reciente al más antiguo.
    def history
      @history ||= begin
        individual = Payment.individual.joins(:order).where(orders: { customer_id: customer.id })
                            .includes(:order, :user).map { |payment| { kind: :individual, date: payment.paid_at.to_date, sort: payment.created_at, record: payment } }
        global = customer.customer_payments.includes(:user, :voided_by, applications: [:order, :user]).map { |payment| { kind: :global, date: payment.paid_on, sort: payment.created_at, record: payment } }

        (individual + global).sort_by { |entry| [entry[:date], entry[:sort]] }.reverse.first(HISTORY_LIMIT)
      end
    end

    private

    def parse_date(value)
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue ArgumentError, TypeError
      @invalid_dates = true
      nil
    end
  end
end
