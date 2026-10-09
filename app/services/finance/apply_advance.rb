module Finance
  # Aplica anticipos del proveedor (lo no imputado de pagos anteriores) a obligaciones
  # pendientes, por una acción explícita. Cada aplicación queda ligada al pago de origen,
  # así un anticipo no se puede usar dos veces.
  class ApplyAdvance
    def self.call(**args)
      new(**args).call
    end

    def initialize(supplier:, user:, allocations:)
      @supplier = supplier
      @user = user
      @allocations = allocations || {}
    end

    def self.available_cents(supplier)
      sources(supplier).sum { |_, unapplied| unapplied }
    end

    # Pagos vigentes con anticipo disponible, del más antiguo al más nuevo: [[pago, sin_imputar]].
    def self.sources(supplier)
      payments = supplier.outgoing_payments.active.order(:paid_on, :id).to_a
      applied = OutgoingPaymentApplication.active.where(outgoing_payment_id: payments.map(&:id)).group(:outgoing_payment_id).sum(:amount_cents)

      payments.filter_map do |payment|
        unapplied = payment.amount_cents - applied.fetch(payment.id, 0)
        [payment, unapplied] if unapplied.positive?
      end
    end

    def call
      result = nil

      ActiveRecord::Base.transaction(requires_new: true) do
        @supplier.lock!
        normalized, obligations, errors = AllocationValidator.call(@supplier, @allocations)
        errors << "Indicá al menos una obligación y un importe a aplicar." if normalized.empty? && errors.empty?

        sources = self.class.sources(@supplier)
        available = sources.sum { |_, unapplied| unapplied }
        errors << "El anticipo disponible es $#{Money.format_pesos(available)} y se intentó aplicar $#{Money.format_pesos(normalized.values.sum)}." if normalized.values.sum > available

        if errors.any?
          result = Result.new(errors: errors.uniq)
          raise ActiveRecord::Rollback
        end

        applications = []
        normalized.each do |obligation_id, cents|
          remaining = cents

          while remaining.positive?
            source, unapplied = sources.first
            take = [remaining, unapplied].min
            applications << source.applications.create!(obligation: obligations.fetch(obligation_id), amount_cents: take, kind: "advance", user: @user)
            remaining -= take
            sources[0] = [source, unapplied - take]
            sources.shift if sources.first[1].zero?
          end
        end

        result = Result.new(applications: applications, advance_cents: available - normalized.values.sum, errors: [])
      end

      result
    rescue ActiveRecord::RecordInvalid => e
      Result.new(errors: e.record.errors.full_messages)
    end
  end
end
