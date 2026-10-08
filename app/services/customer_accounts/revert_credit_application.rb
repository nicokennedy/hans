module CustomerAccounts
  # Revierte una aplicación de saldo a favor a un pedido: la fila se conserva como
  # anulada (con motivo) y el importe vuelve a quedar como saldo a favor de su pago de
  # origen; el saldo del pedido se restablece.
  class RevertCreditApplication
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

      ActiveRecord::Base.transaction do
        customer = @payment.customer_payment&.customer
        errors = []

        if customer && @payment.credit_application?
          customer.lock!
          payment = Payment.lock.find(@payment.id)
          errors << "La aplicación ya fue revertida." if payment.voided?
          errors << "El motivo es obligatorio." if @reason.blank?
        else
          errors << "Este pago no es una aplicación de saldo a favor."
        end

        if errors.any?
          result = Result.new(errors: errors)
          raise ActiveRecord::Rollback
        end

        Order.lock.find(payment.order_id)
        payment.update!(voided_at: Time.current, void_reason: @reason)
        result = Result.new(payments: [payment], credit_cents: payment.amount_cents, errors: [])
      end

      result
    rescue ActiveRecord::RecordInvalid => e
      Result.new(errors: e.record.errors.full_messages)
    end
  end
end
