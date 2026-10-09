require "test_helper"
require_relative "../../support/finance_helpers"

class Finance::ExpensesTest < ActiveSupport::TestCase
  include FinanceHelpers

  def setup
    setup_finance
  end

  def recurrence(frequency: "monthly", starts_on: Date.new(2026, 1, 31), amount: 80_000, **attrs)
    ExpenseRecurrence.create!({ expense_category: @category, frequency: frequency, starts_on: starts_on, amount_cents: pesos(amount), due_days: 5, notes: "Alquiler local" }.merge(attrs))
  end

  test "las categorías iniciales que crea la migración son las pedidas" do
    require Rails.root.join("db/migrate/20261009100000_create_administration_module.rb")

    assert_equal ["Alquiler", "Sueldos y jornales", "Servicios", "Impuestos", "Limpieza y mantenimiento", "Logística y envíos", "Honorarios", "Gastos bancarios", "Publicidad y marketing", "Otros"],
                 CreateAdministrationModule::DEFAULT_CATEGORIES
  end

  test "categorías: nombre único sin importar mayúsculas, editable, desactivable y no borrable si se usa" do
    assert_not ExpenseCategory.new(name: @category.name.upcase).valid?
    @category.update!(name: "Servicios públicos")
    assert_equal "Servicios públicos", @category.reload.name

    make_expense(10)
    assert_not @category.deletable?
    assert_not @category.destroy
    @category.update!(active: false)
    assert_not ExpenseCategory.active.exists?(@category.id)
    assert_equal 1, Expense.count, "el historial conserva la categoría desactivada"
  end

  test "gasto general sin proveedor: obligación pendiente con vencimiento y comprobante" do
    obligation = make_expense(120_000, due_on: Date.new(2026, 10, 10))

    assert_equal "Expense", obligation.source_type
    assert_nil obligation.supplier_id
    assert_equal pesos(120_000), obligation.balance_cents
    assert_equal :pending, obligation.status
    assert_equal @category, obligation.source.expense_category
    assert_not obligation.purchase?
  end

  test "gasto con proveedor, y validaciones: categoría, importe, proveedor inexistente" do
    assert make_expense(10, supplier: @supplier).supplier == @supplier
    result = Finance::SaveExpense.call(user: @admin, attributes: { expense_category_id: nil, amount_cents: 0, accrual_on: Date.current })
    assert_not result.ok?
    assert_not Finance::SaveExpense.call(user: @admin, attributes: { supplier_id: 999_999, expense_category_id: @category.id, amount_cents: 100, accrual_on: Date.current }).ok?
    assert_equal 1, Expense.count
  end

  test "editar un gasto no puede bajar el importe por debajo de lo pagado" do
    obligation = make_expense(100)
    pay(40, supplier: nil, allocations: { obligation.id => pesos(40) }, obligations: [])

    result = Finance::SaveExpense.call(user: @admin, expense: obligation.source, attributes: { expense_category_id: @category.id, amount_cents: pesos(30), accrual_on: obligation.accrual_on })
    assert_not result.ok?
    assert_match(/no puede ser menor a lo ya pagado/, result.errors.join)
    assert Finance::SaveExpense.call(user: @admin, expense: obligation.source, attributes: { expense_category_id: @category.id, amount_cents: pesos(70), accrual_on: obligation.accrual_on }).ok?
  end

  # --- Recurrencias -----------------------------------------------------------------------

  test "fechas de ocurrencia: diaria, semanal y mensual (31/01 -> 28/02 -> 31/03)" do
    assert_equal (Date.new(2026, 10, 1)..Date.new(2026, 10, 4)).to_a, recurrence(frequency: "daily", starts_on: Date.new(2026, 10, 1)).occurrence_dates(Date.new(2026, 10, 4))
    assert_equal [Date.new(2026, 10, 1), Date.new(2026, 10, 8), Date.new(2026, 10, 15)], recurrence(frequency: "weekly", starts_on: Date.new(2026, 10, 1)).occurrence_dates(Date.new(2026, 10, 20))
    assert_equal [Date.new(2026, 1, 31), Date.new(2026, 2, 28), Date.new(2026, 3, 31), Date.new(2026, 4, 30)], recurrence.occurrence_dates(Date.new(2026, 4, 30))
    assert_equal [], recurrence(starts_on: Date.new(2027, 1, 1)).occurrence_dates(Date.new(2026, 10, 1)), "todavía no empezó"
  end

  test "fin por fecha o por cantidad de repeticiones" do
    assert_equal 3, recurrence(starts_on: Date.new(2026, 1, 1), max_occurrences: 3).occurrence_dates(Date.new(2026, 12, 31)).size
    assert_equal [Date.new(2026, 1, 1), Date.new(2026, 2, 1)], recurrence(starts_on: Date.new(2026, 1, 1), ends_on: Date.new(2026, 2, 15)).occurrence_dates(Date.new(2026, 12, 31))
    assert_not ExpenseRecurrence.new(expense_category: @category, frequency: "monthly", starts_on: Date.new(2026, 2, 1), ends_on: Date.new(2026, 1, 1), amount_cents: 100).valid?
    assert_not ExpenseRecurrence.new(expense_category: @category, frequency: "anual", starts_on: Date.new(2026, 2, 1), amount_cents: 100).valid?
    assert_not ExpenseRecurrence.new(expense_category: @category, frequency: "daily", starts_on: Date.new(2026, 2, 1), amount_cents: 100, max_occurrences: 0).valid?
  end

  test "genera una obligación independiente por ocurrencia, con su vencimiento, sin marcarla como pagada" do
    rec = recurrence(starts_on: Date.new(2026, 7, 1), amount: 80_000)

    created = Finance::GenerateRecurringExpenses.call(through: Date.new(2026, 10, 15))

    assert_equal 4, created
    obligations = Obligation.expenses.order(:accrual_on).to_a
    assert_equal [Date.new(2026, 7, 1), Date.new(2026, 8, 1), Date.new(2026, 9, 1), Date.new(2026, 10, 1)], obligations.map(&:accrual_on)
    assert_equal [Date.new(2026, 7, 6), Date.new(2026, 8, 6), Date.new(2026, 9, 6), Date.new(2026, 10, 6)], obligations.map(&:due_on)
    assert obligations.all? { |o| o.amount_cents == pesos(80_000) && o.status == :pending && o.paid_cents.zero? }
    assert obligations.all? { |o| o.source.expense_recurrence_id == rec.id }
    assert_equal 4, OutgoingPaymentApplication.count + 4, "ningún pago generado"
    assert_equal 0, OutgoingPayment.count
  end

  test "prevención de duplicados: ejecutarlo varias veces no genera nada nuevo" do
    recurrence(starts_on: Date.new(2026, 8, 1))
    assert_equal 3, Finance::GenerateRecurringExpenses.call(through: Date.new(2026, 10, 15))

    assert_no_difference ["Expense.count", "Obligation.count"] do
      3.times { assert_equal 0, Finance::GenerateRecurringExpenses.call(through: Date.new(2026, 10, 15)) }
    end

    assert_equal 1, Finance::GenerateRecurringExpenses.call(through: Date.new(2026, 11, 1)), "solo la ocurrencia nueva"
  end

  test "la clave única impide duplicados incluso si el proceso se ejecuta en paralelo" do
    rec = recurrence(starts_on: Date.new(2026, 10, 1))
    Finance::GenerateRecurringExpenses.call(through: Date.new(2026, 10, 1))

    assert_raises(ActiveRecord::RecordNotUnique) do
      Expense.create!(expense_category: @category, expense_recurrence: rec, occurrence_on: Date.new(2026, 10, 1))
    end
    assert_not Finance::GenerateRecurringExpenses.create_occurrence(rec, Date.new(2026, 10, 1))
  end

  test "modificar una ocurrencia no altera la serie ni se vuelve a generar" do
    rec = recurrence(starts_on: Date.new(2026, 8, 1), amount: 80_000)
    Finance::GenerateRecurringExpenses.call(through: Date.new(2026, 10, 15))
    september = Obligation.expenses.find_by(accrual_on: Date.new(2026, 9, 1))

    result = Finance::SaveExpense.call(user: @admin, expense: september.source, attributes: { expense_category_id: @category.id, amount_cents: pesos(95_000), accrual_on: september.accrual_on, due_on: Date.new(2026, 9, 20), notes: "Aumento puntual" })
    assert result.ok?

    assert_equal pesos(95_000), september.reload.amount_cents
    assert_equal [pesos(80_000)], Obligation.expenses.where.not(id: september.id).pluck(:amount_cents).uniq
    assert_equal pesos(80_000), rec.reload.amount_cents
    assert_equal 0, Finance::GenerateRecurringExpenses.call(through: Date.new(2026, 10, 15))
    assert_equal pesos(95_000), september.reload.amount_cents, "regenerar no pisa lo editado"
  end

  test "una ocurrencia no se borra (se anula) y por eso no se regenera" do
    rec = recurrence(starts_on: Date.new(2026, 10, 1))
    Finance::GenerateRecurringExpenses.call(through: Date.new(2026, 10, 1))
    expense = Expense.last

    assert_not Finance::DestroySource.call(expense).ok?
    assert Expense.exists?(expense.id)

    assert Finance::VoidObligation.call(obligation: expense.obligation, user: @admin, reason: "no corresponde este mes").ok?
    assert_equal 0, Finance::GenerateRecurringExpenses.call(through: Date.new(2026, 10, 15))
    assert_equal 1, Expense.count
    assert expense.obligation.reload.voided?
  end

  test "finalizar o desactivar una recurrencia detiene la generación y conserva lo generado" do
    rec = recurrence(starts_on: Date.new(2026, 8, 1))
    Finance::GenerateRecurringExpenses.call(through: Date.new(2026, 9, 15))
    assert_equal 2, Expense.count

    rec.update!(active: false)
    assert_equal 0, Finance::GenerateRecurringExpenses.call(through: Date.new(2026, 12, 31))
    assert_equal 2, Expense.count
    assert rec.finished?

    other = recurrence(starts_on: Date.new(2026, 8, 1), ends_on: Date.new(2026, 9, 10))
    assert_equal 2, Finance::GenerateRecurringExpenses.call(through: Date.new(2026, 12, 31), recurrence: other)
    assert other.finished?(Date.new(2026, 12, 31))
  end

  test "las ocurrencias pueden pagarse una por una sin afectar a las otras" do
    recurrence(starts_on: Date.new(2026, 8, 1), amount: 50_000)
    Finance::GenerateRecurringExpenses.call(through: Date.new(2026, 10, 15))
    august = Obligation.expenses.find_by(accrual_on: Date.new(2026, 8, 1))

    assert pay(50_000, supplier: nil, allocations: { august.id => pesos(50_000) }, obligations: []).ok?
    assert_equal [:paid, :pending, :pending], Obligation.expenses.order(:accrual_on).map(&:status)
  end
end
