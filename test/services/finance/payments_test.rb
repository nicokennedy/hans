require "test_helper"
require_relative "../../support/finance_helpers"

class Finance::PaymentsTest < ActiveSupport::TestCase
  include FinanceHelpers

  def setup
    setup_finance
  end

  def three_invoices
    [make_purchase(100_000, accrual_on: Date.new(2026, 10, 1), due_on: Date.new(2026, 10, 10), document_number: "001"),
     make_purchase(150_000, accrual_on: Date.new(2026, 10, 2), due_on: Date.new(2026, 10, 20), document_number: "002"),
     make_purchase(200_000, accrual_on: Date.new(2026, 10, 3), due_on: Date.new(2026, 10, 30), document_number: "003")]
  end

  # --- Imputación automática ------------------------------------------------------------

  test "ejemplo del enunciado: $300.000 sobre 100/150/200 propone 100/150/50 y deja $150.000 pendientes" do
    a, b, c = three_invoices
    suggestion = Finance::Distribution.suggest(Finance::Distribution.pending_obligations(@supplier).to_a, pesos(300_000))

    assert_equal({ a.id => pesos(100_000), b.id => pesos(150_000), c.id => pesos(50_000) }, suggestion.allocations)
    assert_equal 0, suggestion.unapplied_cents

    result = pay(300_000)
    assert result.ok?
    assert_equal [0, 0, pesos(150_000)], balances(a, b, c)
    assert_equal pesos(150_000), @supplier.reload.pending_cents
    assert_equal [:paid, :paid, :partial], [a, b, c].map { |o| Obligation.find(o.id).status }
  end

  test "criterio: primero el vencimiento más cercano (sin vencimiento al final) y luego la fecha de compra" do
    late = make_purchase(10, accrual_on: Date.new(2026, 10, 1), due_on: Date.new(2026, 12, 1))
    no_due = make_purchase(10, accrual_on: Date.new(2026, 9, 1), due_on: nil)
    early_old = make_purchase(10, accrual_on: Date.new(2026, 9, 5), due_on: Date.new(2026, 11, 1))
    early_new = make_purchase(10, accrual_on: Date.new(2026, 9, 10), due_on: Date.new(2026, 11, 1))

    order = Finance::Distribution.pending_obligations(@supplier).map(&:id)
    assert_equal [early_old.id, early_new.id, late.id, no_due.id], order
  end

  test "no propone anuladas, pagadas, de otro proveedor ni más que el saldo" do
    a = make_purchase(100)
    voided = make_purchase(100)
    Finance::VoidObligation.call(obligation: voided, user: @admin, reason: "error")
    paid = make_purchase(50)
    pay(50, allocations: { paid.id => pesos(50) }, obligations: [])
    make_purchase(999, supplier: @other_supplier)

    pending = Finance::Distribution.pending_obligations(@supplier).to_a
    assert_equal [a.id], pending.map(&:id)
    suggestion = Finance::Distribution.suggest(pending, pesos(1_000))
    assert_equal({ a.id => pesos(100) }, suggestion.allocations)
    assert_equal pesos(900), suggestion.unapplied_cents
  end

  # --- Pagos: completo, parcial, manual, varias facturas ---------------------------------------

  test "pago completo y pago parcial" do
    a = make_purchase(100)
    assert pay(30, obligations: [a]).ok?
    assert_equal [:partial, pesos(70)], [Obligation.find(a.id).status, Obligation.find(a.id).balance_cents]
    assert pay(70).ok?
    assert_equal [:paid, 0], [Obligation.find(a.id).status, Obligation.find(a.id).balance_cents]
  end

  test "edición manual de imputaciones: dejar facturas sin pagar y repartir como se quiera" do
    a, b, c = three_invoices
    result = pay(150_000, allocations: { c.id => pesos(120_000), b.id => pesos(30_000) })

    assert result.ok?
    assert_equal [pesos(100_000), pesos(120_000), pesos(80_000)], balances(a, b, c)
    assert_equal 0, result.advance_cents
    assert_equal 2, result.applications.size
  end

  test "un pago que cancela varias facturas se registra una sola vez" do
    a, b, c = three_invoices
    result = pay(450_000)

    assert result.ok?
    assert_equal 1, OutgoingPayment.count
    assert_equal 3, OutgoingPaymentApplication.count
    assert_equal [0, 0, 0], balances(a, b, c)
    assert_equal pesos(450_000), result.payment.applied_cents
    assert result.applications.all? { |app| app.kind == "distribution" && app.user == @admin }
  end

  test "pago en un solo comprobante con medio, referencia, fecha y usuario guardados" do
    a = make_purchase(100)
    result = pay(100, method: "check", reference: "Cheque 000123", paid_on: Date.current - 3)

    payment = result.payment
    assert_equal "check", payment.payment_method
    assert_equal "Cheque 000123", payment.reference
    assert_equal Date.current - 3, payment.paid_on
    assert_equal @admin, payment.user
    assert_in_delta Time.current.to_f, payment.created_at.to_f, 5
    assert_equal "Cheque", payment.method_label
  end

  # --- Validaciones ------------------------------------------------------------------------------

  test "no se puede imputar más que el saldo, más que el pago, negativos ni obligaciones ajenas o anuladas" do
    a = make_purchase(100)
    foreign = make_purchase(100, supplier: @other_supplier)
    voided = make_purchase(100)
    Finance::VoidObligation.call(obligation: voided, user: @admin, reason: "x")

    assert_not pay(500, allocations: { a.id => pesos(101) }).ok?
    assert_not pay(50, allocations: { a.id => pesos(30), voided.id => pesos(30) }).ok?
    assert_not pay(100, allocations: { a.id => -5 }).ok?
    assert_not pay(100, allocations: { foreign.id => pesos(10) }).ok?
    assert_not pay(100, allocations: { voided.id => pesos(10) }).ok?
    assert_not pay(100, allocations: { 99_999_999 => pesos(10) }).ok?
    assert_not pay(100, allocations: { "x" => pesos(10) }).ok?
    assert_not pay(0, allocations: {}).ok?
    assert_not Finance::RegisterPayment.call(supplier: @supplier, user: @admin, amount_cents: 100, paid_on: Date.current + 1, payment_method: "cash", allocations: {}).ok?
    assert_not Finance::RegisterPayment.call(supplier: @supplier, user: @admin, amount_cents: 100, paid_on: Date.current, payment_method: "trueque", allocations: {}).ok?
    assert_not Finance::RegisterPayment.call(supplier: @supplier, user: nil, amount_cents: 100, paid_on: Date.current, payment_method: "cash", allocations: {}).ok?
    assert_equal 0, OutgoingPayment.count
    assert_equal 0, OutgoingPaymentApplication.count
    assert_equal pesos(100), Obligation.find(a.id).balance_cents
  end

  test "integridad transaccional: si una imputación falla no queda ningún registro a medias" do
    a = make_purchase(100)
    b = make_purchase(100)

    assert_no_difference ["OutgoingPayment.count", "OutgoingPaymentApplication.count"] do
      assert_not pay(300, allocations: { a.id => pesos(100), b.id => pesos(100.01.to_i + 1) }).ok?
    end
    assert_equal [pesos(100), pesos(100)], balances(a, b)
  end

  test "protección ante pagos duplicados por doble envío (mismo token)" do
    a = make_purchase(100)
    token = SecureRandom.uuid

    first = pay(40, token: token, obligations: [a])
    second = pay(40, token: token, obligations: [a])

    assert first.ok? && !first.duplicate?
    assert second.ok? && second.duplicate?
    assert_equal first.payment.id, second.payment.id
    assert_equal 1, OutgoingPayment.count
    assert_equal pesos(60), Obligation.find(a.id).balance_cents
  end

  # --- Anticipos -------------------------------------------------------------------------------------

  test "un pago mayor a la deuda deja el excedente como anticipo, sin perder dinero" do
    a = make_purchase(100)
    result = pay(250)

    assert result.ok?
    assert_equal pesos(150), result.advance_cents
    assert_equal pesos(150), result.payment.unapplied_cents
    assert_equal pesos(150), Finance::ApplyAdvance.available_cents(@supplier)
    assert_equal 0, Obligation.find(a.id).balance_cents
    assert_equal pesos(250), result.payment.applied_cents + result.payment.unapplied_cents
  end

  test "anticipo explícito: pago sin obligaciones pendientes" do
    result = pay(80, allocations: {})
    assert result.ok?
    assert_equal pesos(80), @supplier.reload.advance_cents
    assert_equal 0, @supplier.pending_cents
  end

  test "aplicación posterior del anticipo a una obligación nueva, solo con la acción explícita" do
    pay(100, allocations: {})
    later = make_purchase(60)

    assert_equal pesos(60), Obligation.find(later.id).balance_cents, "cargar la compra NO consume el anticipo"
    result = Finance::ApplyAdvance.call(supplier: @supplier, user: @admin, allocations: { later.id => pesos(60) })

    assert result.ok?
    assert_equal 0, Obligation.find(later.id).balance_cents
    assert_equal pesos(40), result.advance_cents
    application = result.applications.first
    assert_equal "advance", application.kind
    assert_equal OutgoingPayment.first.id, application.outgoing_payment_id
  end

  test "el mismo anticipo no se puede usar dos veces ni aplicar de más" do
    pay(100, allocations: {})
    a = make_purchase(80)
    b = make_purchase(80)

    assert Finance::ApplyAdvance.call(supplier: @supplier, user: @admin, allocations: { a.id => pesos(80) }).ok?
    second = Finance::ApplyAdvance.call(supplier: @supplier, user: @admin, allocations: { b.id => pesos(80) })
    assert_not second.ok?
    assert_match(/anticipo disponible/, second.errors.join)
    assert Finance::ApplyAdvance.call(supplier: @supplier, user: @admin, allocations: { b.id => pesos(20) }).ok?
    assert_equal 0, Finance::ApplyAdvance.available_cents(@supplier)
    assert_not Finance::ApplyAdvance.call(supplier: @supplier, user: @admin, allocations: { b.id => pesos(1) }).ok?
  end

  test "los anticipos se toman del pago más antiguo primero y quedan ligados a su origen" do
    old = pay(10, allocations: {}, paid_on: Date.current - 10).payment
    new = pay(10, allocations: {}, paid_on: Date.current - 1).payment
    order = make_purchase(15)

    result = Finance::ApplyAdvance.call(supplier: @supplier, user: @admin, allocations: { order.id => pesos(15) })
    by_source = result.applications.group_by(&:outgoing_payment_id).transform_values { |apps| apps.sum(&:amount_cents) }
    assert_equal({ old.id => pesos(10), new.id => pesos(5) }, by_source)
  end

  test "un pago sin proveedor (gasto) debe imputarse completo y solo a gastos sin proveedor" do
    expense = make_expense(100)
    other = make_expense(100, supplier: @supplier)

    assert_not pay(150, supplier: nil, allocations: { expense.id => pesos(100) }, obligations: []).ok?, "no admite anticipos"
    assert_not pay(100, supplier: nil, allocations: { other.id => pesos(100) }, obligations: []).ok?, "no a obligaciones de un proveedor"
    assert_not pay(100, supplier: nil, allocations: {}, obligations: []).ok?
    assert pay(100, supplier: nil, allocations: { expense.id => pesos(100) }, obligations: []).ok?
    assert_equal :paid, Obligation.find(expense.id).status
  end

  # --- Anulación ----------------------------------------------------------------------------------------

  test "anular un pago conserva el registro, revierte imputaciones y restablece los saldos" do
    a, b, c = three_invoices
    payment = pay(300_000).payment

    result = Finance::VoidPayment.call(payment: payment, user: @admin, reason: "Transferencia duplicada")

    assert result.ok?
    payment.reload
    assert payment.voided?
    assert_equal @admin, payment.voided_by
    assert_equal "Transferencia duplicada", payment.void_reason
    assert_equal [pesos(100_000), pesos(150_000), pesos(200_000)], balances(a, b, c)
    assert_equal 1, OutgoingPayment.count, "el registro se conserva"
    assert_equal 3, payment.applications.count
    assert payment.applications.all?(&:voided?)
    assert_equal 0, payment.unapplied_cents
    assert_equal pesos(450_000), @supplier.reload.pending_cents
  end

  test "anular un pago con anticipo desaparece el anticipo no usado" do
    pay(100, allocations: {})
    payment = OutgoingPayment.last
    assert_equal pesos(100), @supplier.advance_cents

    assert Finance::VoidPayment.call(payment: payment, user: @admin, reason: "error").ok?
    assert_equal 0, @supplier.reload.advance_cents
  end

  test "motivo obligatorio y no se anula dos veces" do
    pay(10, allocations: {})
    payment = OutgoingPayment.last

    assert_not Finance::VoidPayment.call(payment: payment, user: @admin, reason: "").ok?
    assert Finance::VoidPayment.call(payment: payment, user: @admin, reason: "x").ok?
    assert_match(/ya está anulado/, Finance::VoidPayment.call(payment: payment, user: @admin, reason: "x").errors.join)
  end

  test "si el anticipo ya se aplicó a otra obligación la anulación se bloquea y se explica; revirtiendo primero se puede" do
    pay(100, allocations: {})
    payment = OutgoingPayment.last
    later = make_purchase(30)
    application = Finance::ApplyAdvance.call(supplier: @supplier, user: @admin, allocations: { later.id => pesos(30) }).applications.first

    blocked = Finance::VoidPayment.call(payment: payment, user: @admin, reason: "x")
    assert_not blocked.ok?
    assert_match(/ya se aplicó a otras obligaciones/, blocked.errors.join)
    assert_not payment.reload.voided?
    assert_equal 0, Obligation.find(later.id).balance_cents, "nada se tocó por detrás"

    assert Finance::RevertAdvanceApplication.call(application: application, user: @admin, reason: "Factura equivocada").ok?
    assert application.reload.voided?
    assert_equal pesos(30), Obligation.find(later.id).balance_cents
    assert_equal pesos(100), Finance::ApplyAdvance.available_cents(@supplier)
    assert Finance::VoidPayment.call(payment: payment, user: @admin, reason: "x").ok?
  end

  test "revertir exige motivo, solo aplica a anticipos y no se repite" do
    a = make_purchase(10)
    distribution = pay(10, obligations: [a]).applications.first
    assert_not Finance::RevertAdvanceApplication.call(application: distribution, user: @admin, reason: "x").ok?

    pay(10, allocations: {})
    later = make_purchase(10)
    application = Finance::ApplyAdvance.call(supplier: @supplier, user: @admin, allocations: { later.id => pesos(10) }).applications.first
    assert_not Finance::RevertAdvanceApplication.call(application: application, user: @admin, reason: "").ok?
    assert Finance::RevertAdvanceApplication.call(application: application, user: @admin, reason: "ok").ok?
    assert_not Finance::RevertAdvanceApplication.call(application: application, user: @admin, reason: "otra").ok?
  end

  test "una compra o gasto con pagos no se borra ni se anula directamente; sin pagos sí se puede" do
    paid = make_purchase(100)
    pay(10, obligations: [paid])
    free = make_purchase(50)

    assert_not Finance::DestroySource.call(paid.source).ok?
    assert Purchase.exists?(paid.source_id)
    blocked = Finance::VoidObligation.call(obligation: paid, user: @admin, reason: "x")
    assert_not blocked.ok?
    assert_match(/pagos imputados/, blocked.errors.join)

    assert Finance::VoidPayment.call(payment: OutgoingPayment.last, user: @admin, reason: "x").ok?
    assert_not Finance::DestroySource.call(paid.reload.source).ok?, "aunque el pago esté anulado, el historial impide borrar"
    assert Finance::VoidObligation.call(obligation: paid, user: @admin, reason: "compra duplicada").ok?
    assert paid.reload.voided?
    assert_equal :voided, paid.status

    assert Finance::DestroySource.call(free.source).ok?
    assert_not Purchase.exists?(free.source_id)
    assert_not Obligation.exists?(free.id)
  end

  test "los pagos anulados no cuentan para el saldo de la obligación" do
    a = make_purchase(100)
    pay(100, obligations: [a])
    assert_equal :paid, Obligation.find(a.id).status
    Finance::VoidPayment.call(payment: OutgoingPayment.last, user: @admin, reason: "x")
    assert_equal :pending, Obligation.find(a.id).status
    assert pay(100, obligations: [Obligation.find(a.id)]).ok?
  end
end
