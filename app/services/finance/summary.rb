module Finance
  # Resumen administrativo de un mes (o de todo un año). Distingue tres fechas que NO se
  # mezclan: devengamiento/compra (accrual_on: cuándo se genera la obligación), vencimiento
  # (due_on) y pago (paid_on). Compras y gastos son obligaciones distintas, así que no se
  # suman dos veces; un pago NUNCA es un gasto nuevo. Esto no es un estado de resultados.
  class Summary
    DUE_SOON_DAYS = 7
    # El locale es de la app no trae nombres de mes: se definen acá.
    MONTH_NAMES = %w[Enero Febrero Marzo Abril Mayo Junio Julio Agosto Septiembre Octubre Noviembre Diciembre].freeze

    attr_reader :year, :month, :today

    def initialize(year: nil, month: nil, today: Date.current)
      @today = today
      @year = year.to_i.between?(2000, 2100) ? year.to_i : today.year
      @month = month.to_s.empty? ? today.month : (month.to_i.between?(1, 12) ? month.to_i : nil)
      @month = nil if month.to_s == "all"
    end

    def period
      month ? Date.new(year, month, 1)..Date.new(year, month, -1) : Date.new(year, 1, 1)..Date.new(year, 12, 31)
    end

    def period_label
      month ? "#{MONTH_NAMES[month - 1]} #{year}" : "Año #{year}"
    end

    def purchases_cents
      accrued(Obligation.purchases).sum(:amount_cents)
    end

    def expenses_cents
      accrued(Obligation.expenses).sum(:amount_cents)
    end

    # Egresos de caja del período (fecha de pago), incluidos los anticipos.
    def paid_in_period_cents
      OutgoingPayment.active.where(paid_on: period).sum(:amount_cents)
    end

    # Total de obligaciones pendientes hoy (no depende del período elegido).
    def pending_cents
      Obligation.outstanding.sum("obligations.amount_cents - #{Obligation::PAID_SQL}")
    end

    def overdue
      bucket(Obligation.outstanding.where("obligations.due_on < ?", today))
    end

    def due_soon
      bucket(Obligation.outstanding.where(due_on: today..(today + DUE_SOON_DAYS)))
    end

    def advances_cents
      advances_by_supplier.values.sum
    end

    # Saldo por proveedor: pendiente, anticipos disponibles y neto. Solo proveedores con movimiento de saldo.
    def supplier_balances
      @supplier_balances ||= begin
        pending = Obligation.outstanding.where.not(supplier_id: nil).group(:supplier_id).sum("obligations.amount_cents - #{Obligation::PAID_SQL}")
        advances = advances_by_supplier
        suppliers = Supplier.where(id: pending.keys | advances.keys).index_by(&:id)

        (pending.keys | advances.keys).map do |id|
          { supplier: suppliers[id], pending_cents: pending.fetch(id, 0), advance_cents: advances.fetch(id, 0), net_cents: pending.fetch(id, 0) - advances.fetch(id, 0) }
        end.sort_by { |row| [-row[:pending_cents], row[:supplier].name.downcase] }
      end
    end

    def top_pending_suppliers(limit = 10)
      supplier_balances.select { |row| row[:pending_cents].positive? }.first(limit)
    end

    # Gastos generales del período por categoría (fecha de devengamiento).
    def expenses_by_category
      rows = accrued(Obligation.expenses).joins("INNER JOIN expenses ON expenses.id = obligations.source_id")
                                         .joins("INNER JOIN expense_categories ON expense_categories.id = expenses.expense_category_id")
                                         .group("expense_categories.name").pluck("expense_categories.name", Arel.sql("SUM(obligations.amount_cents)"), Arel.sql("COUNT(*)"))
      rows.map { |name, cents, count| { category: name, cents: cents.to_i, count: count.to_i } }.sort_by { |row| -row[:cents] }
    end

    # Base para un futuro estado de resultados mensual (no implementado): devengamientos por mes.
    def accrual_by_month
      (1..12).to_h do |m|
        range = Date.new(year, m, 1)..Date.new(year, m, -1)
        [m, { purchases_cents: Obligation.active.purchases.where(accrual_on: range).sum(:amount_cents), expenses_cents: Obligation.active.expenses.where(accrual_on: range).sum(:amount_cents) }]
      end
    end

    private

    def accrued(scope)
      scope.active.where(accrual_on: period)
    end

    def bucket(scope)
      { count: scope.count, cents: scope.sum("obligations.amount_cents - #{Obligation::PAID_SQL}") }
    end

    def advances_by_supplier
      payments = OutgoingPayment.active.where.not(supplier_id: nil)
      applied = OutgoingPaymentApplication.active.where(outgoing_payment_id: payments.select(:id)).group(:outgoing_payment_id).sum(:amount_cents)
      payments.pluck(:id, :supplier_id, :amount_cents).each_with_object(Hash.new(0)) do |(id, supplier_id, amount), memo|
        free = amount - applied.fetch(id, 0)
        memo[supplier_id] += free if free.positive?
      end.select { |_, cents| cents.positive? }
    end
  end
end
