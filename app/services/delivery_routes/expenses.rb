module DeliveryRoutes
  # Gastos pagados con el efectivo de un recorrido (R4, D2). Se guardan como DeliveryExpense y
  # pasan a Administración (Expense) recién al confirmar el cierre: así se contabilizan una sola
  # vez. Con el recorrido bloqueado, para que dos gastos simultáneos no superen el efectivo.
  #
  # Límite: el repartidor no puede registrar un gasto mayor al efectivo disponible del recorrido
  # ("Supera el efectivo disponible ($X). Avisale a administración."). Administración sí, como
  # excepción con confirmación explícita y motivo; si los gastos quedan por encima de los
  # cobros, la rendición lo muestra como importe pendiente de resolver (no se compensa solo).
  # Idempotente por request_token. Corregir = anular con motivo + registrar el nuevo.
  class Expenses
    Result = Struct.new(:expense, :errors, :already, keyword_init: true) do
      def ok?
        errors.blank?
      end
    end

    def initialize(route, user)
      @route = route
      @user = user
    end

    def record(concept:, amount_cents:, request_token:, notes: nil, exception: false, exception_reason: nil)
      run(request_token) do
        create(concept, amount_cents, notes, request_token, exception, exception_reason, available: available_cents)
      end
    end

    # amount_cents 0 = anular el gasto.
    def correct(expense, concept:, amount_cents:, reason:, request_token:, notes: nil, exception: false, exception_reason: nil)
      reason = reason.to_s.squish
      run(request_token) do
        old = DeliveryExpense.lock.find(expense.id)
        next ["Ese gasto no es de este recorrido."] unless old.delivery_route_id == @route.id
        next ["Ese gasto ya fue corregido. Revisá la lista."] if old.voided?
        next ["Escribí el motivo de la corrección."] if reason.blank?
        next ["El importe no es válido."] unless amount_cents.is_a?(Integer) && amount_cents >= 0

        available = [Settlement.new(@route).expected_cents + old.amount_cents, 0].max
        old.update!(voided_at: Time.current, voided_by: @user, void_reason: reason)
        if amount_cents.positive?
          created = create(concept, amount_cents, notes.nil? ? old.notes : notes, request_token, exception, exception_reason,
                           available: available, replaces: old, event: false)
          next created if created.is_a?(Array)

          Events.record(@route, @user, "expense_corrected", reason: reason, old_expense_id: old.id, expense_id: created.id,
                        before_cents: old.amount_cents, after_cents: amount_cents,
                        summary: "Corrigió el gasto \"#{old.concept}\": de $#{money(old.amount_cents)} a $#{money(amount_cents)}. Motivo: #{reason}.")
          created
        else
          Events.record(@route, @user, "expense_voided", reason: reason, old_expense_id: old.id, before_cents: old.amount_cents,
                        summary: "Anuló el gasto \"#{old.concept}\" de $#{money(old.amount_cents)}. Motivo: #{reason}.")
          old
        end
      end
    end

    private

    def available_cents
      Settlement.new(@route).available_cents
    end

    def run(token)
      token = token.to_s.strip
      return Result.new(errors: ["Falta el identificador del formulario. Volvé a intentar."]) if token.blank?

      result = nil
      DeliveryRoute.transaction do
        @route = DeliveryRoute.lock.find(@route.id)
        if (existing = DeliveryExpense.find_by(request_token: token))
          result = existing.delivery_route_id == @route.id ? Result.new(expense: existing, errors: [], already: true) : Result.new(errors: ["No se pudo registrar el gasto."])
          next
        end
        if (denied = Access.money_error(@route, @user))
          result = Result.new(errors: [denied])
          raise ActiveRecord::Rollback
        end

        outcome = yield
        if outcome.is_a?(Array)
          result = Result.new(errors: outcome)
          raise ActiveRecord::Rollback
        end
        result = Result.new(expense: outcome, errors: [], already: false)
      end
      result
    rescue ActiveRecord::RecordNotUnique
      existing = DeliveryExpense.find_by(request_token: token)
      existing ? Result.new(expense: existing, errors: [], already: true) : Result.new(errors: ["No se pudo registrar el gasto. Volvé a intentar."])
    end

    def create(concept, amount_cents, notes, token, exception, exception_reason, available:, replaces: nil, event: true)
      concept = concept.to_s.squish
      return ["Elegí o escribí el concepto del gasto."] if concept.blank?
      return ["Escribí el importe del gasto."] unless amount_cents.is_a?(Integer) && amount_cents.positive?

      admin_exception = false
      if amount_cents > available
        return ["Supera el efectivo disponible ($#{money(available)}). Avisale a administración."] unless @user.admin?

        unless exception && exception_reason.to_s.squish.present?
          return ["Supera el efectivo disponible del recorrido ($#{money(available)}). Para registrarlo igual, confirmá la excepción y escribí el motivo."]
        end

        admin_exception = true
      end

      expense = @route.expenses.create!(
        concept: concept, amount_cents: amount_cents, notes: notes.to_s.strip.presence, spent_at: Time.current,
        admin_exception: admin_exception, exception_reason: (exception_reason.to_s.squish if admin_exception),
        request_token: token.to_s.strip, created_by: @user, replaces: replaces
      )
      if event
        extra = admin_exception ? " (excepción de administración: #{expense.exception_reason})" : ""
        Events.record(@route, @user, "expense_recorded", expense_id: expense.id, amount_cents: amount_cents,
                      summary: "Registró el gasto \"#{concept}\" de $#{money(amount_cents)}#{extra}.")
      end
      expense
    end

    def money(cents)
      CustomerAccounts::Money.format_pesos(cents)
    end
  end
end
