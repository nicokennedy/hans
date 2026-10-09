module Finance
  # Genera las ocurrencias de gastos recurrentes que ya corresponden (fecha <= hoy). Es
  # idempotente: la clave única (recurrencia, fecha) impide duplicados aunque se ejecute
  # muchas veces o en paralelo. Nunca marca nada como pagado. Cada ocurrencia es un gasto
  # independiente que se puede editar sin tocar la serie.
  class GenerateRecurringExpenses
    MAX_PER_RUN = 500

    def self.call(through: Date.current, recurrence: nil)
      scope = recurrence ? ExpenseRecurrence.where(id: recurrence.id) : ExpenseRecurrence.active
      created = 0

      scope.find_each do |rec|
        existing = rec.expenses.pluck(:occurrence_on).to_set
        missing = rec.occurrence_dates(through).reject { |date| existing.include?(date) }.first(MAX_PER_RUN)

        missing.each { |date| created += 1 if create_occurrence(rec, date) }
      end

      created
    end

    def self.create_occurrence(rec, date)
      return false if Expense.exists?(expense_recurrence_id: rec.id, occurrence_on: date)

      created = false

      ActiveRecord::Base.transaction(requires_new: true) do
        result = SaveExpense.call(
          user: nil, recurrence: rec, occurrence_on: date,
          attributes: { supplier_id: rec.supplier_id, expense_category_id: rec.expense_category_id, amount_cents: rec.amount_cents,
                        accrual_on: date, due_on: date + rec.due_days, document_type: rec.document_type, notes: rec.notes }
        )
        raise ActiveRecord::Rollback unless result.ok?

        created = true
      end

      created
    rescue ActiveRecord::RecordNotUnique
      false
    end
  end
end
