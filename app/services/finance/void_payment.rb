module Finance
  # Anula un pago (conserva el registro con quién, cuándo y por qué): sus imputaciones se
  # anulan, los saldos de las obligaciones se restablecen y el anticipo sin usar desaparece.
  # Si parte del anticipo ya se aplicó a obligaciones posteriores, se bloquea: primero hay
  # que revertir esas aplicaciones (Finance::RevertAdvanceApplication).
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
        @payment.supplier&.lock!
        payment = OutgoingPayment.lock.find(@payment.id)

        errors = []
        errors << "El pago ya está anulado." if payment.voided?
        errors << "El motivo de la anulación es obligatorio." if @reason.blank?

        advances = payment.applications.active.where(kind: "advance").includes(:obligation).to_a
        if advances.any?
          detail = advances.map { |a| "#{a.obligation.document_label} ($#{Money.format_pesos(a.amount_cents)})" }.join(", ")
          errors << "No se puede anular: parte de su anticipo ya se aplicó a otras obligaciones (#{detail}). Revertí primero esas aplicaciones."
        end

        if errors.any?
          result = Result.new(payment: payment, errors: errors)
          raise ActiveRecord::Rollback
        end

        now = Time.current
        applications = payment.applications.active.order(:obligation_id).to_a
        Obligation.where(id: applications.map(&:obligation_id)).lock.order(:id).load

        payment.update!(voided_at: now, voided_by: @user, void_reason: @reason)
        applications.each { |application| application.update!(voided_at: now, void_reason: "Pago anulado: #{@reason}") }

        result = Result.new(payment: payment, applications: applications, advance_cents: 0, errors: [])
      end

      result
    rescue ActiveRecord::RecordInvalid => e
      Result.new(errors: e.record.errors.full_messages)
    end
  end
end
