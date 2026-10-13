module Retail
  # Registra un pago de un pedido minorista (cuenta propia, sin relación con Payment /
  # CustomerPayment / cuenta corriente mayorista). Con el pedido bloqueado:
  #  - el importe es un entero de centavos > 0;
  #  - no puede superar el saldo pendiente salvo que se confirme explícitamente el excedente
  #    (queda marcado en el pago y el pedido muestra el excedente como saldo a favor);
  #  - request_token evita el doble envío del formulario.
  class RegisterPayment
    def self.call(**args)
      new(**args).call
    end

    def initialize(order:, user:, amount:, paid_at:, payment_method:, notes: nil, allow_excess: false, request_token: nil)
      @order = order
      @user = user
      @amount = amount
      @paid_at = paid_at
      @payment_method = payment_method.to_s
      @notes = notes
      @allow_excess = allow_excess.to_s.in?(%w[1 true on])
      @request_token = request_token.presence
    end

    def call
      result = nil
      amount_cents = @amount.is_a?(Integer) ? @amount : Money.parse_pesos(@amount)
      date = parse_date

      errors = []
      errors << "El importe no es válido." if amount_cents.nil?
      errors << "El importe debe ser mayor a cero." if amount_cents && amount_cents <= 0
      errors << "La fecha del pago no es válida." if date.nil?
      errors << "El medio de pago no es válido." unless RetailOrder::PAYMENT_METHODS.include?(@payment_method)
      return Result.new(record: @order, errors: errors) if errors.any?

      ActiveRecord::Base.transaction(requires_new: true) do
        order = RetailOrder.lock.find(@order.id)

        if @request_token && (existing = order.retail_order_payments.find_by(request_token: @request_token))
          result = Result.new(record: existing, errors: [], duplicate: true)
          next
        end

        if order.canceled?
          result = Result.new(record: order, errors: ["El pedido está cancelado: no se pueden registrar pagos nuevos."])
          next
        end

        excess = amount_cents > order.pending_balance_cents
        if excess && !@allow_excess
          result = Result.new(
            record: order,
            errors: ["El importe ($#{Money.format_pesos(amount_cents)}) supera el saldo pendiente ($#{Money.format_pesos(order.pending_balance_cents)}). Si es correcto, confirmá el excedente."]
          )
          next
        end

        payment = order.retail_order_payments.create!(
          amount_cents: amount_cents, paid_at: date, payment_method: @payment_method, notes: @notes.to_s.strip.presence,
          user: @user, excess_confirmed: excess, request_token: @request_token
        )
        order.recalculate_payment_state!
        result = Result.new(record: payment, errors: [])
      end

      result
    rescue ActiveRecord::RecordInvalid => e
      Result.new(record: @order, errors: e.record.errors.full_messages)
    rescue ActiveRecord::RecordNotUnique
      Result.new(record: @order, errors: [], duplicate: true)
    end

    private

    def parse_date
      return @paid_at if @paid_at.is_a?(Date)
      return nil if @paid_at.blank?

      Date.iso8601(@paid_at.to_s)
    rescue ArgumentError
      nil
    end
  end
end
