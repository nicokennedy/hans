module Retail
  # Anula un pago minorista (corrección auditable): el registro se conserva con quién, cuándo y
  # por qué; deja de contar en el saldo y el estado de pago se recalcula. Nunca se borra.
  class VoidPayment
    def self.call(**args)
      new(**args).call
    end

    def initialize(payment:, user:, reason:)
      @payment = payment
      @user = user
      @reason = reason.to_s.strip
    end

    def call
      result = nil

      ActiveRecord::Base.transaction(requires_new: true) do
        order = RetailOrder.lock.find(@payment.retail_order_id)
        payment = order.retail_order_payments.find(@payment.id)
        errors = []
        errors << "El pago ya está anulado." if payment.voided?
        errors << "El motivo de la anulación es obligatorio." if @reason.blank?

        if errors.any?
          result = Result.new(record: payment, errors: errors)
          next
        end

        payment.update!(voided_at: Time.current, voided_by: @user, void_reason: @reason)
        order.recalculate_payment_state!
        result = Result.new(record: payment, errors: [])
      end

      result
    rescue ActiveRecord::RecordInvalid => e
      Result.new(errors: e.record.errors.full_messages)
    end
  end
end
