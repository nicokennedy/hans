module CustomerAccounts
  # Registra un pago de cuenta corriente: UNA fila CustomerPayment (el ingreso real) y
  # una fila Payment por cada pedido al que se aplica. El sobrante queda como saldo a
  # favor. Todo en una transacción, con el cliente y los pedidos bloqueados
  # (SELECT ... FOR UPDATE) y revalidado contra el estado actual, así dos pagos
  # simultáneos no pueden exceder un saldo. El request_token evita el doble envío.
  class RegisterPayment
    def self.call(**args)
      new(**args).call
    end

    def initialize(customer:, user:, amount_cents:, paid_on:, payment_method:, allocations:, reference: nil, note: nil, request_token: nil)
      @customer = customer
      @user = user
      @amount_cents = amount_cents
      @paid_on = paid_on
      @payment_method = payment_method.to_s
      @allocations = allocations || {}
      @reference = reference.to_s.strip.presence
      @note = note.to_s.strip.presence
      @request_token = request_token.to_s.strip.presence
    end

    def call
      result = nil

      ActiveRecord::Base.transaction do
        @customer.lock!

        if (existing = duplicate_payment)
          result = Result.new(customer_payment: existing, payments: existing.applications.to_a, credit_cents: existing.unapplied_cents, errors: [], duplicate: true)
          next
        end

        errors = basic_errors
        normalized, orders, allocation_errors = AllocationValidator.call(@customer, @allocations)
        errors += allocation_errors
        errors << "Lo distribuido ($#{Money.format_pesos(normalized.values.sum)}) supera el monto recibido ($#{Money.format_pesos(@amount_cents.to_i)})." if @amount_cents.is_a?(Integer) && normalized.values.sum > @amount_cents

        if errors.any?
          result = Result.new(errors: errors.uniq)
          raise ActiveRecord::Rollback
        end

        customer_payment = @customer.customer_payments.create!(
          amount_cents: @amount_cents, paid_on: @paid_on, payment_method: @payment_method,
          reference: @reference, note: @note, user: @user, request_token: @request_token
        )

        payments = normalized.map do |order_id, cents|
          orders.fetch(order_id).payments.create!(
            amount_cents: cents, paid_at: @paid_on.in_time_zone, payment_method: @payment_method,
            note: application_note(customer_payment), user: @user,
            customer_payment: customer_payment, application_kind: "distribution"
          )
        end

        result = Result.new(customer_payment: customer_payment, payments: payments, credit_cents: @amount_cents - normalized.values.sum, errors: [], duplicate: false)
      end

      result
    rescue ActiveRecord::RecordNotUnique
      existing = @customer.customer_payments.find_by(request_token: @request_token)
      return Result.new(errors: ["No se pudo registrar el pago."]) unless existing

      Result.new(customer_payment: existing, payments: existing.applications.to_a, credit_cents: existing.unapplied_cents, errors: [], duplicate: true)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(errors: e.record.errors.full_messages)
    end

    private

    def duplicate_payment
      return nil unless @request_token

      CustomerPayment.find_by(request_token: @request_token, customer_id: @customer.id)
    end

    def basic_errors
      errors = []
      errors << "El importe recibido debe ser un monto mayor a cero." unless @amount_cents.is_a?(Integer) && @amount_cents.positive?
      errors << "La fecha del pago no es válida." unless @paid_on.is_a?(Date)
      errors << "La fecha del pago no puede ser futura." if @paid_on.is_a?(Date) && @paid_on > Date.current
      errors << "Elegí un medio de pago válido." unless Order.payment_method_selecteds.key?(@payment_method)
      errors << "El pago debe registrarse con un usuario." if @user.nil?
      errors
    end

    def application_note(customer_payment)
      ["Cuenta corriente ##{customer_payment.id}", ("Ref: #{@reference}" if @reference), @note].compact.join(" · ")
    end
  end
end
