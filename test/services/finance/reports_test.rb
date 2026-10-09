require "test_helper"
require_relative "../../support/finance_helpers"

class Finance::ReportsTest < ActiveSupport::TestCase
  include FinanceHelpers

  TODAY = Date.new(2026, 10, 15)

  def setup
    setup_finance
    @rent = ExpenseCategory.create!(name: "Alquiler #{rand(1_000_000)}")
  end

  def summary(month: 10, year: 2026)
    Finance::Summary.new(year: year, month: month, today: TODAY)
  end

  def account(supplier = @supplier, **options)
    Finance::SupplierAccount.new(supplier, **options)
  end

  # --- Cuenta corriente del proveedor -----------------------------------------------------------------

  test "total de obligaciones − pagos imputados = saldo pendiente; anticipos y neto por separado" do
    make_purchase(100, accrual_on: Date.new(2026, 9, 1))
    make_purchase(150, accrual_on: Date.new(2026, 9, 10))
    pay(120, obligations: Finance::Distribution.pending_obligations(@supplier).to_a)
    pay(40, allocations: {})
    a = account

    assert_equal pesos(250), a.total_obligations_cents
    assert_equal pesos(120), a.applied_cents
    assert_equal pesos(130), a.pending_cents, "250 − 120 imputado"
    assert_equal pesos(40), a.advance_cents
    assert_equal pesos(160), a.payments_cents
    assert_equal pesos(90), a.net_cents, "pendiente − anticipos = obligaciones − pagos"
    assert_equal a.total_obligations_cents - a.payments_cents, a.net_cents
  end

  test "los saldos coinciden exactamente con los movimientos registrados (obligación por obligación)" do
    a = make_purchase(100)
    b = make_purchase(70)
    pay(60, obligations: [a, b])
    pay(200, obligations: Finance::Distribution.pending_obligations(@supplier).to_a)

    acc = account
    assert_equal Obligation.where(supplier: @supplier).with_paid.sum(&:balance_cents), acc.pending_cents
    assert_equal OutgoingPayment.where(supplier: @supplier).sum { |p| p.unapplied_cents }, acc.advance_cents
    assert_equal @supplier.reload.pending_cents, acc.pending_cents
    assert_equal @supplier.advance_cents, acc.advance_cents
  end

  test "movimientos en orden cronológico con saldo neto acumulado; anulados visibles pero sin sumar" do
    make_purchase(100, accrual_on: Date.new(2026, 9, 1))
    make_purchase(50, accrual_on: Date.new(2026, 9, 20))
    voided = make_purchase(999, accrual_on: Date.new(2026, 9, 25))
    Finance::VoidObligation.call(obligation: voided, user: @admin, reason: "error")
    paid = pay(80, paid_on: Date.new(2026, 9, 10), obligations: [Obligation.where(supplier: @supplier).order(:accrual_on).first]).payment

    entries = account.entries
    assert_equal [Date.new(2026, 9, 1), Date.new(2026, 9, 10), Date.new(2026, 9, 20), Date.new(2026, 9, 25)], entries.map(&:date)
    assert_equal %i[purchase payment purchase purchase], entries.map(&:kind)
    assert_equal [pesos(100), pesos(20), pesos(70), pesos(70)], entries.map(&:running_cents), "el anulado no suma"
    assert_equal 0, entries.last.debit_cents
    assert_equal paid, entries[1].record
  end

  test "filtro por fechas del movimiento: lista el rango pero los totales siguen siendo los reales" do
    make_purchase(100, accrual_on: Date.new(2026, 8, 1))
    make_purchase(50, accrual_on: Date.new(2026, 10, 1))
    acc = account(from: "2026-09-01", to: "2026-10-31")

    assert_equal 1, acc.entries.size
    assert_equal pesos(150), acc.total_obligations_cents
    assert_equal pesos(150), acc.entries.first.running_cents, "el acumulado arranca en el historial real"
    assert account(from: "basura").invalid_dates?
  end

  test "la cuenta de un proveedor no incluye movimientos de otros" do
    make_purchase(10)
    make_purchase(999, supplier: @other_supplier)
    pay(500, supplier: @other_supplier, allocations: {})

    assert_equal pesos(10), account.total_obligations_cents
    assert_equal 0, account.payments_cents
    assert_equal 1, account.entries.size
  end

  # --- Resumen administrativo -------------------------------------------------------------------------

  test "compras y gastos del período por fecha de devengamiento, sin sumarse entre sí" do
    make_purchase(100, accrual_on: Date.new(2026, 10, 2))
    make_purchase(40, accrual_on: Date.new(2026, 9, 28))
    make_expense(30, accrual_on: Date.new(2026, 10, 5))
    make_expense(7, accrual_on: Date.new(2026, 11, 1))
    s = summary

    assert_equal pesos(100), s.purchases_cents
    assert_equal pesos(30), s.expenses_cents
    assert_equal pesos(40), summary(month: 9).purchases_cents
    assert_equal pesos(140), summary(month: nil.to_s.presence || "all").purchases_cents, "todo el año"
    assert_equal pesos(37), summary(month: "all").expenses_cents
  end

  test "un pago no es un gasto nuevo: pagar no modifica compras ni gastos del período" do
    a = make_purchase(100, accrual_on: Date.new(2026, 10, 2))
    make_expense(30, accrual_on: Date.new(2026, 10, 5))
    before = [summary.purchases_cents, summary.expenses_cents]

    pay(100, obligations: [a], paid_on: Date.new(2026, 10, 8))

    assert_equal before, [summary.purchases_cents, summary.expenses_cents]
    assert_equal pesos(100), summary.paid_in_period_cents
    assert_equal pesos(30), summary.pending_cents
  end

  test "pagado del período por fecha de pago (incluye anticipos), distinto de la fecha de compra" do
    a = make_purchase(100, accrual_on: Date.new(2026, 9, 1))
    pay(100, obligations: [a], paid_on: Date.new(2026, 10, 3))
    pay(20, allocations: {}, paid_on: Date.new(2026, 9, 5))

    assert_equal pesos(100), summary(month: 10).paid_in_period_cents
    assert_equal pesos(20), summary(month: 9).paid_in_period_cents
    assert_equal 0, summary(month: 10).purchases_cents, "la compra es de septiembre"
  end

  test "pagos anulados no cuentan como pagados en el período" do
    a = make_purchase(100)
    pay(100, obligations: [a], paid_on: Date.new(2026, 10, 3))
    Finance::VoidPayment.call(payment: OutgoingPayment.last, user: @admin, reason: "x")

    assert_equal 0, summary.paid_in_period_cents
    assert_equal pesos(100), summary.pending_cents
  end

  test "obligaciones vencidas y próximas a vencer (7 días), sin contar pagadas ni anuladas" do
    overdue = make_purchase(100, due_on: Date.new(2026, 10, 10), accrual_on: Date.new(2026, 10, 1))
    make_purchase(50, due_on: Date.new(2026, 10, 20), accrual_on: Date.new(2026, 10, 1))
    make_purchase(70, due_on: Date.new(2026, 12, 1), accrual_on: Date.new(2026, 10, 1))
    paid_overdue = make_purchase(30, due_on: Date.new(2026, 10, 2), accrual_on: Date.new(2026, 10, 1))
    pay(30, obligations: [paid_overdue])
    voided = make_purchase(999, due_on: Date.new(2026, 10, 1), accrual_on: Date.new(2026, 10, 1))
    Finance::VoidObligation.call(obligation: voided, user: @admin, reason: "x")
    pay(40, obligations: [overdue])
    s = summary

    assert_equal({ count: 1, cents: pesos(60) }, s.overdue)
    assert_equal({ count: 1, cents: pesos(50) }, s.due_soon)
    assert_equal pesos(180), s.pending_cents
    assert Obligation.find(overdue.id).overdue?(TODAY)
  end

  test "saldo por proveedor y proveedores con mayor saldo pendiente" do
    make_purchase(100)
    make_purchase(300, supplier: @other_supplier)
    pay(50, supplier: @other_supplier, allocations: {})
    balances_by = summary.supplier_balances.index_by { |row| row[:supplier] }

    assert_equal pesos(100), balances_by[@supplier][:pending_cents]
    assert_equal pesos(300), balances_by[@other_supplier][:pending_cents]
    assert_equal pesos(50), balances_by[@other_supplier][:advance_cents]
    assert_equal pesos(250), balances_by[@other_supplier][:net_cents]
    assert_equal [@other_supplier, @supplier], summary.top_pending_suppliers.map { |row| row[:supplier] }
    assert_equal pesos(50), summary.advances_cents
  end

  test "gastos por categoría del período" do
    make_expense(100, category: @rent, accrual_on: Date.new(2026, 10, 1))
    make_expense(50, category: @rent, accrual_on: Date.new(2026, 10, 9))
    make_expense(20, category: @category, accrual_on: Date.new(2026, 10, 9))
    make_expense(999, category: @category, accrual_on: Date.new(2026, 9, 9))

    rows = summary.expenses_by_category
    assert_equal [{ category: @rent.name, cents: pesos(150), count: 2 }, { category: @category.name, cents: pesos(20), count: 1 }], rows
  end

  test "los anulados no entran en compras, gastos ni categorías" do
    a = make_purchase(100, accrual_on: Date.new(2026, 10, 2))
    e = make_expense(40, category: @rent, accrual_on: Date.new(2026, 10, 2))
    Finance::VoidObligation.call(obligation: a, user: @admin, reason: "x")
    Finance::VoidObligation.call(obligation: e, user: @admin, reason: "x")

    assert_equal 0, summary.purchases_cents
    assert_equal 0, summary.expenses_cents
    assert_equal [], summary.expenses_by_category
    assert_equal 0, summary.pending_cents
  end

  test "información lista para un futuro estado de resultados: devengamientos por mes (sin implementarlo)" do
    make_purchase(100, accrual_on: Date.new(2026, 3, 2))
    make_expense(40, accrual_on: Date.new(2026, 3, 9))
    month = summary.accrual_by_month

    assert_equal 12, month.size
    assert_equal({ purchases_cents: pesos(100), expenses_cents: pesos(40) }, month[3])
    assert_equal({ purchases_cents: 0, expenses_cents: 0 }, month[4])
    assert_not summary.respond_to?(:result), "no hay 'resultado' ni 'ganancia'"
    assert_not summary.respond_to?(:profit)
  end

  # --- CSV ---------------------------------------------------------------------------------------------------

  test "CSV de compras: columnas, importes sin separadores y neutralización de fórmulas" do
    a = make_purchase(1_500, document_number: "0001-1", notes: "=HYPERLINK(\"http://x\")")
    pay(500, obligations: [a])
    csv = Finance::CsvExport.purchases(Obligation.purchases.with_paid.includes(:supplier))
    rows = CSV.parse(csv.delete_prefix("﻿"), headers: true)

    assert csv.start_with?("﻿")
    assert_equal ["Fecha", "Proveedor", "Tipo de comprobante", "Número", "Total", "Pagado", "Saldo", "Estado", "Vencimiento", "Comentario"], rows.headers
    row = rows.first
    assert_equal @supplier.name, row["Proveedor"]
    assert_equal "1500.00", row["Total"]
    assert_equal "500.00", row["Pagado"]
    assert_equal "1000.00", row["Saldo"]
    assert_equal "Parcialmente pagado", row["Estado"]
    assert_equal "'=HYPERLINK(\"http://x\")", row["Comentario"], "un texto que empieza con = no se ejecuta como fórmula"
  end

  test "CSV de la cuenta corriente del proveedor" do
    make_purchase(100, accrual_on: Date.new(2026, 9, 1))
    pay(30, paid_on: Date.new(2026, 9, 5), reference: "TRF 1")
    csv = Finance::CsvExport.supplier_account(account)
    rows = CSV.parse(csv.delete_prefix("﻿"), headers: true)

    assert_equal 2, rows.size
    assert_equal ["Compra", "Pago"], rows.map { |r| r["Tipo"] }
    assert_equal ["100.00", "0.00"], rows.map { |r| r["Obligación (debe)"] }
    assert_equal ["0.00", "30.00"], rows.map { |r| r["Pago (haber)"] }
    assert_equal ["100.00", "70.00"], rows.map { |r| r["Saldo neto acumulado"] }
    assert_match(/Ref: TRF 1/, rows[1]["Detalle"])
  end
end
