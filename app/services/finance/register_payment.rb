module Finance
  # Registra un pago: UNA fila OutgoingPayment (el egreso real) y una imputación por cada
  # obligación a la que se aplica. Lo no imputado queda como ANTICIPO del proveedor (solo
  # con proveedor). Transaccional, con proveedor y obligaciones bloqueados y revalidado
  # contra el estado actual; el request_token evita duplicados por doble envío.
  class RegisterPayment
    def self.call(**args)
      new(**args).call
    end

    def initialize(supplier:, user:, amount_cents:, paid_on:, payment_method:, allocations:, reference: nil, note: nil, request_token: nil, upload: nil)
      @supplier = supplier
      @user = user
      @amount_cents = amount_cents
      @paid_on = paid_on
      @payment_method = payment_method.to_s
      @allocations = allocations || {}
      @reference = reference.to_s.strip.presence
      @note = note.to_s.strip.presence
      @request_token = request_token.to_s.strip.presence
      @upload = upload
    end

    def call
      result = nil

      ActiveRecord::Base.transaction(requires_new: true) do
        @supplier&.lock!

        if (existing = duplicate_payment)
          result = Result.new(payment: existing, applications: existing.applications.to_a, advance_cents: existing.unapplied_cents, errors: [], duplicate: true)
          next
        end

        errors = basic_errors
        normalized, obligations, allocation_errors = AllocationValidator.call(@supplier, @allocations)
        errors += allocation_errors
        applied = normalized.values.sum
        errors << "Lo imputado ($#{Money.format_pesos(applied)}) supera el importe pagado ($#{Money.format_pesos(@amount_cents.to_i)})." if @amount_cents.is_a?(Integer) && applied > @amount_cents
        errors << "Un pago sin proveedor debe imputarse completo a gastos (no admite anticipos)." if @supplier.nil? && @amount_cents.is_a?(Integer) && applied != @amount_cents
        errors << "Indicá a qué obligaciones se imputa el pago." if @supplier.nil? && normalized.empty?

        if errors.any?
          result = Result.new(errors: errors.uniq)
          raise ActiveRecord::Rollback
        end

        payment = OutgoingPayment.create!(
          supplier: @supplier, amount_cents: @amount_cents, paid_on: @paid_on, payment_method: @payment_method,
          reference: @reference, note: @note, user: @user, request_token: @request_token
        )

        applications = normalized.map do |obligation_id, cents|
          payment.applications.create!(obligation: obligations.fetch(obligation_id), amount_cents: cents, kind: "distribution", user: @user)
        end

        attach_upload(payment)
        result = Result.new(payment: payment, applications: applications, advance_cents: @amount_cents - applied, errors: [], duplicate: false)
      end

      result
    rescue ActiveRecord::RecordNotUnique
      existing = OutgoingPayment.find_by(request_token: @request_token)
      return Result.new(errors: ["No se pudo registrar el pago."]) unless existing

      Result.new(payment: existing, applications: existing.applications.to_a, advance_cents: existing.unapplied_cents, errors: [], duplicate: true)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(errors: e.record.errors.full_messages)
    end

    private

    def duplicate_payment
      return nil unless @request_token

      OutgoingPayment.find_by(request_token: @request_token)
    end

    def basic_errors
      errors = []
      errors << "El importe pagado debe ser mayor a cero." unless @amount_cents.is_a?(Integer) && @amount_cents.positive?
      errors << "La fecha del pago no es válida." unless @paid_on.is_a?(Date)
      errors << "La fecha del pago no puede ser futura." if @paid_on.is_a?(Date) && @paid_on > Date.current
      errors << "Elegí un medio de pago válido." unless OutgoingPayment::METHODS.key?(@payment_method)
      errors << "El pago debe registrarse con un usuario." if @user.nil?
      errors
    end

    def attach_upload(payment)
      return unless @upload

      attachment = AdministrationAttachment.build_from_upload(payment, @upload, user: @user)
      attachment.save!
    end
  end
end
