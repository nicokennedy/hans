module DeliveryRoutes
  # Envío y cierre de la rendición de UN recorrido (R4). Con el recorrido bloqueado (FOR UPDATE)
  # para que no se crucen con un cobro o gasto en curso, ni dos cierres simultáneos.
  #
  #  - submit (repartidor): congela cobros, gastos y efectivo a entregar, con fecha y hora.
  #    Desde ahí el repartidor ya no puede cambiar cobros ni gastos.
  #  - confirm (solo admin): recalcula (por si administración corrigió algo después del envío),
  #    registra el efectivo contado, la diferencia de caja (D3: NUNCA como gasto; motivo
  #    obligatorio si hay diferencia) y el importe pendiente de resolver si los gastos superan
  #    los cobros. Crea los gastos en Administración (Finance::SaveExpense, pagados en efectivo)
  #    una sola vez. Un recorrido confirmado no se reabre.
  class Settlements
    Result = Struct.new(:route, :errors, :already, keyword_init: true) do
      def ok?
        errors.blank?
      end
    end

    DEFAULT_CATEGORY_NAME = "Logística y envíos".freeze

    def self.default_category
      ExpenseCategory.find_by(name: DEFAULT_CATEGORY_NAME)
    end

    def initialize(route, user)
      @route = route
      @user = user
    end

    def submit
      transaction do |route|
        next ["Solo el repartidor del recorrido envía la rendición."] unless @user&.driver? && route.driver_id == @user.id
        next :already if route.submitted? || route.confirmed?
        next ["Este recorrido no se puede enviar."] unless route.open_for_driver?

        summary = Settlement.new(route)
        route.update!(status: "submitted", submitted_at: Time.current, submitted_by: @user,
                      collected_cents: summary.collected_cents, other_income_cents: summary.other_income_cents, expenses_cents: summary.expenses_cents, expected_cash_cents: summary.expected_cents)
        Events.record(route, @user, "settlement_submitted", collected_cents: summary.collected_cents, other_income_cents: summary.other_income_cents, expenses_cents: summary.expenses_cents,
                      expected_cents: summary.expected_cents,
                      summary: "#{@user.display_name} envió la rendición: cobró $#{money(summary.collected_cents)}, gastó $#{money(summary.expenses_cents)}, entrega $#{money(summary.to_deliver_cents)}.")
        nil
      end
    end

    # categories: { delivery_expense_id => expense_category_id }
    def confirm(counted_cents:, note: nil, categories: {})
      note = note.to_s.squish.presence
      transaction do |route|
        next ["Solo administración confirma el cierre."] unless @user&.admin?
        next :already if route.confirmed?
        next ["El repartidor todavía no envió la rendición."] unless route.submitted?
        next ["Escribí el efectivo que recibiste y contaste (puede ser 0)."] unless counted_cents.is_a?(Integer) && counted_cents >= 0

        summary = Settlement.new(route)
        difference = counted_cents - summary.to_deliver_cents
        next ["Hay una diferencia de caja (#{difference.negative? ? 'faltan' : 'sobran'} $#{money(difference.abs)}): escribí el motivo."] if difference != 0 && note.nil?
        next ["El importe pendiente de resolver ($#{money(summary.unresolved_cents)}) necesita una nota."] if summary.unresolved_cents.positive? && note.nil?

        errors = post_expenses(route, summary.counted_expenses, categories || {})
        next errors if errors.any?

        route.update!(status: "confirmed", confirmed_at: Time.current, confirmed_by: @user,
                      collected_cents: summary.collected_cents, other_income_cents: summary.other_income_cents, expenses_cents: summary.expenses_cents, expected_cash_cents: summary.expected_cents,
                      counted_cash_cents: counted_cents, difference_cents: difference, unresolved_cents: summary.unresolved_cents, confirmation_note: note)
        Events.record(route, @user, "settlement_confirmed", reason: note, counted_cents: counted_cents, expected_cents: summary.expected_cents,
                      to_deliver_cents: summary.to_deliver_cents, difference_cents: difference, unresolved_cents: summary.unresolved_cents,
                      summary: confirm_summary(summary, counted_cents, difference))
        nil
      end
    end

    private

    def transaction
      result = nil
      DeliveryRoute.transaction do
        route = DeliveryRoute.lock.find(@route.id)
        outcome = yield(route)
        if outcome.is_a?(Array)
          result = Result.new(route: route, errors: outcome)
          raise ActiveRecord::Rollback
        end
        result = Result.new(route: route, errors: [], already: outcome == :already)
      end
      result
    end

    def post_expenses(route, expenses, categories)
      default = self.class.default_category
      expenses.reject(&:expense_id).each do |delivery_expense|
        category_id = categories[delivery_expense.id] || categories[delivery_expense.id.to_s] || default&.id
        saved = Finance::SaveExpense.call(
          user: @user,
          attributes: { expense_category_id: category_id, amount_cents: delivery_expense.amount_cents, accrual_on: delivery_expense.spent_at.to_date,
                        notes: ["Gasto de reparto: #{route.title} del #{I18n.l(route.date, format: '%d/%m/%Y')}", delivery_expense.concept,
                                delivery_expense.notes, "registrado por #{delivery_expense.created_by.display_name}"].compact.join(" · ") },
          pay_now: { amount_cents: delivery_expense.amount_cents, paid_on: delivery_expense.spent_at.to_date, payment_method: "cash",
                     request_token: "reparto-gasto-#{delivery_expense.id}" }
        )
        return saved.errors.map { |e| "Gasto \"#{delivery_expense.concept}\": #{e}" } unless saved.ok?

        delivery_expense.update!(expense: saved.record)
      end
      []
    end

    def confirm_summary(summary, counted, difference)
      text = "Confirmó el cierre: esperado $#{money(summary.to_deliver_cents)}, recibido $#{money(counted)}"
      text += difference.zero? ? ", sin diferencia" : ", diferencia de caja: #{difference.negative? ? 'faltan' : 'sobran'} $#{money(difference.abs)}"
      text += ", pendiente de resolver $#{money(summary.unresolved_cents)}" if summary.unresolved_cents.positive?
      "#{text}."
    end

    def money(cents)
      CustomerAccounts::Money.format_pesos(cents)
    end
  end
end
