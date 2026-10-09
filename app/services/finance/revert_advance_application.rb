module Finance
  # Revierte la aplicación de un anticipo a una obligación: la fila queda anulada (con
  # motivo), el importe vuelve a ser anticipo de su pago de origen y la obligación recupera
  # su saldo.
  class RevertAdvanceApplication
    def self.call(**args)
      new(**args).call
    end

    def initialize(application:, user:, reason:)
      @application = application
      @user = user
      @reason = reason.to_s.strip
    end

    def call
      result = nil

      ActiveRecord::Base.transaction(requires_new: true) do
        errors = []
        payment = @application.outgoing_payment

        if @application.advance?
          payment.supplier&.lock!
          application = OutgoingPaymentApplication.lock.find(@application.id)
          errors << "La aplicación ya fue revertida." if application.voided?
          errors << "El motivo es obligatorio." if @reason.blank?
        else
          errors << "Esta imputación no es una aplicación de anticipo."
        end

        if errors.any?
          result = Result.new(errors: errors)
          raise ActiveRecord::Rollback
        end

        Obligation.lock.find(application.obligation_id)
        application.update!(voided_at: Time.current, void_reason: @reason)
        result = Result.new(applications: [application], advance_cents: application.amount_cents, errors: [])
      end

      result
    rescue ActiveRecord::RecordInvalid => e
      Result.new(errors: e.record.errors.full_messages)
    end
  end
end
