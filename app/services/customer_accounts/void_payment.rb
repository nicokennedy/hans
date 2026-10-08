module CustomerAccounts
  # Anula un pago de cuenta corriente: el registro se conserva (con quién, cuándo y por
  # qué), sus aplicaciones a pedidos se anulan (los saldos de los pedidos vuelven a lo que
  # eran) y el saldo a favor sin usar desaparece con él. Si parte del crédito ya se
  # aplicó a pedidos posteriores, NO se anula: primero hay que revertir esas
  # aplicaciones (ver RevertCreditApplication). Nunca se modifican otros movimientos
  # por detrás.
  class VoidPayment
    def self.call(**args)
      new(**args).call
    end

    def initialize(customer_payment:, user:, reason:)
      @customer_payment = customer_payment
      @user = user
      @reason = reason.to_s.strip
    end

    def call
      result = nil

      ActiveRecord::Base.transaction do
        customer = @customer_payment.customer
        customer.lock!
        payment = CustomerPayment.lock.find(@customer_payment.id)

        errors = []
        errors << "El pago ya está anulado." if payment.voided?
        errors << "El motivo de la anulación es obligatorio." if @reason.blank?

        credit_applications = payment.applications.active.where(application_kind: "credit").includes(:order).to_a
        if credit_applications.any?
          detail = credit_applications.map { |a| "#{a.order.number} ($#{Money.format_pesos(a.amount_cents)})" }.join(", ")
          errors << "No se puede anular: parte de su saldo a favor ya se aplicó a pedidos posteriores (#{detail}). Revertí primero esas aplicaciones."
        end

        if errors.any?
          result = Result.new(customer_payment: payment, errors: errors)
          raise ActiveRecord::Rollback
        end

        now = Time.current
        applications = payment.applications.active.includes(:order).order(:order_id).to_a
        Order.where(id: applications.map(&:order_id)).lock.order(:id).load

        payment.update!(voided_at: now, voided_by: @user, void_reason: @reason)
        applications.each { |application| application.update!(voided_at: now, void_reason: "Pago de cuenta corriente anulado: #{@reason}") }

        result = Result.new(customer_payment: payment, payments: applications, credit_cents: 0, errors: [])
      end

      result
    rescue ActiveRecord::RecordInvalid => e
      Result.new(errors: e.record.errors.full_messages)
    end
  end
end
