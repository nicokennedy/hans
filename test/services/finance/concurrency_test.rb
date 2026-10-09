require "test_helper"
require_relative "../../support/finance_helpers"

# Transacciones reales en hilos distintos (los tests transaccionales no sirven acá);
# cada prueba limpia lo que crea.
class Finance::ConcurrencyTest < ActiveSupport::TestCase
  include FinanceHelpers

  self.use_transactional_tests = false

  def setup
    setup_finance
  end

  def teardown
    ids = Obligation.where(supplier_id: [@supplier.id, @other_supplier.id]).or(Obligation.where(supplier_id: nil)).pluck(:id)
    OutgoingPaymentApplication.where(obligation_id: ids).delete_all
    OutgoingPayment.where(supplier_id: [@supplier.id, @other_supplier.id]).or(OutgoingPayment.where(supplier_id: nil)).delete_all
    AdministrationAttachment.delete_all
    sources = Obligation.where(id: ids).pluck(:source_type, :source_id)
    Obligation.where(id: ids).delete_all
    PurchaseItem.where(purchase_id: sources.select { |t, _| t == "Purchase" }.map(&:last)).delete_all
    Purchase.where(id: sources.select { |t, _| t == "Purchase" }.map(&:last)).delete_all
    Expense.where(id: sources.select { |t, _| t == "Expense" }.map(&:last)).delete_all
    Supplier.where(id: [@supplier.id, @other_supplier.id]).delete_all
    @category.delete
    @admin.delete
  end

  def in_threads(count)
    barrier = Queue.new
    threads = Array.new(count) do |i|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.pop
          yield i
        end
      end
    end
    count.times { barrier << true }
    threads.map(&:value)
  end

  test "dos pagos simultáneos por el mismo saldo: solo uno se imputa y nunca se sobreimputa" do
    obligation = make_purchase(100)

    results = in_threads(2) do |i|
      pay(100, obligations: [], allocations: { obligation.id => pesos(100) }, token: "t#{i}-#{SecureRandom.hex(4)}")
    end

    assert_equal 1, results.count(&:ok?), results.map(&:errors).inspect
    assert_equal 0, Obligation.find(obligation.id).balance_cents
    assert_equal pesos(100), OutgoingPaymentApplication.where(obligation_id: obligation.id).sum(:amount_cents)
    assert_equal 1, OutgoingPayment.where(supplier_id: @supplier.id).count
  end

  test "pagos simultáneos a un gasto sin proveedor (se bloquea la obligación)" do
    expense = make_expense(100)

    results = in_threads(2) { |i| pay(100, supplier: nil, obligations: [], allocations: { expense.id => pesos(100) }, token: "g#{i}-#{SecureRandom.hex(4)}") }

    assert_equal 1, results.count(&:ok?)
    assert_equal 0, Obligation.find(expense.id).balance_cents
  end

  test "el mismo formulario reenviado a la vez (mismo token) registra un solo pago" do
    obligation = make_purchase(100)
    token = SecureRandom.uuid

    results = in_threads(3) { pay(40, obligations: [], allocations: { obligation.id => pesos(40) }, token: token) }

    assert results.all?(&:ok?)
    assert_equal 1, results.count { |r| !r.duplicate? }
    assert_equal 1, OutgoingPayment.where(supplier_id: @supplier.id).count
    assert_equal pesos(60), Obligation.find(obligation.id).balance_cents
  end

  test "dos aplicaciones simultáneas del mismo anticipo no lo usan dos veces" do
    pay(50, allocations: {})
    a = make_purchase(50)
    b = make_purchase(50)

    results = in_threads(2) { |i| Finance::ApplyAdvance.call(supplier: @supplier, user: @admin, allocations: { (i.zero? ? a : b).id => pesos(50) }) }

    assert_equal 1, results.count(&:ok?)
    assert_equal 0, Finance::ApplyAdvance.available_cents(@supplier)
    assert_equal pesos(50), OutgoingPaymentApplication.where(obligation_id: [a.id, b.id]).sum(:amount_cents)
  end

  test "la generación de recurrentes en paralelo no duplica ocurrencias" do
    rec = ExpenseRecurrence.create!(expense_category: @category, frequency: "monthly", starts_on: Date.new(2026, 8, 1), amount_cents: pesos(10))

    in_threads(3) { Finance::GenerateRecurringExpenses.call(through: Date.new(2026, 10, 15)) }

    assert_equal 3, Expense.where(expense_recurrence_id: rec.id).count
    assert_equal 3, Expense.where(expense_recurrence_id: rec.id).distinct.count(:occurrence_on)
    ids = Expense.where(expense_recurrence_id: rec.id).pluck(:id)
    Obligation.where(source_type: "Expense", source_id: ids).delete_all
    Expense.where(id: ids).delete_all
    rec.delete
  end
end
