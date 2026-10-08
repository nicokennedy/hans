module CustomerAccounts
  # Aplica saldo a favor (lo no aplicado de pagos de cuenta corriente anteriores) a
  # pedidos pendientes, por una acción EXPLÍCITA del administrador. El crédito se toma
  # de los pagos más antiguos primero y cada aplicación queda ligada al pago de origen,
  # así un mismo crédito no se puede usar dos veces. Nada se consume automáticamente.
  class ApplyCredit
    def self.call(**args)
      new(**args).call
    end

    def initialize(customer:, user:, allocations:)
      @customer = customer
      @user = user
      @allocations = allocations || {}
    end

    def self.available_cents(customer)
      sources(customer).sum { |_, unapplied| unapplied }
    end

    # Pagos activos con crédito disponible, del más antiguo al más nuevo: [[pago, sin_aplicar]].
    def self.sources(customer)
      payments = customer.customer_payments.active.order(:paid_on, :id).to_a
      applied = Payment.active.where(customer_payment_id: payments.map(&:id)).group(:customer_payment_id).sum(:amount_cents)

      payments.filter_map do |payment|
        unapplied = payment.amount_cents - applied.fetch(payment.id, 0)
        [payment, unapplied] if unapplied.positive?
      end
    end

    def call
      result = nil

      ActiveRecord::Base.transaction do
        @customer.lock!
        normalized, orders, errors = AllocationValidator.call(@customer, @allocations)
        errors << "Indicá al menos un pedido y un importe a aplicar." if normalized.empty? && errors.empty?

        sources = self.class.sources(@customer)
        available = sources.sum { |_, unapplied| unapplied }
        errors << "El saldo a favor disponible es $#{Money.format_pesos(available)} y se intentó aplicar $#{Money.format_pesos(normalized.values.sum)}." if normalized.values.sum > available

        if errors.any?
          result = Result.new(errors: errors.uniq)
          raise ActiveRecord::Rollback
        end

        payments = []
        normalized.each do |order_id, cents|
          remaining = cents

          while remaining.positive?
            source, unapplied = sources.first
            take = [remaining, unapplied].min

            payments << orders.fetch(order_id).payments.create!(
              amount_cents: take, paid_at: Date.current.in_time_zone, payment_method: source.payment_method,
              note: "Saldo a favor del pago ##{source.id} (#{source.paid_on.strftime('%d/%m/%Y')})",
              user: @user, customer_payment: source, application_kind: "credit"
            )

            remaining -= take
            sources[0] = [source, unapplied - take]
            sources.shift if sources.first[1].zero?
          end
        end

        result = Result.new(payments: payments, credit_cents: available - normalized.values.sum, errors: [])
      end

      result
    rescue ActiveRecord::RecordInvalid => e
      Result.new(errors: e.record.errors.full_messages)
    end
  end
end
