require "test_helper"
require_relative "../../support/customer_account_helpers"

class CustomerAccounts::RegisterPaymentTest < ActiveSupport::TestCase
  include CustomerAccountHelpers

  def setup
    setup_account
  end

  test "pago individual existente: sigue funcionando igual y no es un pago de cuenta corriente" do
    order = make_order(10)
    payment = order.payments.create!(amount_cents: pesos(4_000), paid_at: Time.current, payment_method: "cash_on_delivery", note: "Seña")

    assert payment.individual?
    assert_nil payment.customer_payment_id
    assert_nil payment.application_kind
    assert_nil payment.user_id
    order.reload
    assert_equal pesos(4_000), order.amount_paid_cents
    assert_equal "partial", order.payment_status
    assert_equal pesos(6_000), order.balance_due_cents
    assert_equal 0, CustomerPayment.count
  end

  test "pago global aplicado a un solo pedido" do
    order = make_order(50)
    result = register(50_000)

    assert result.ok?
    assert_equal 1, CustomerPayment.count
    payment = result.customer_payment
    assert_equal pesos(50_000), payment.amount_cents
    assert_equal @admin, payment.user
    assert_equal [order.id], payment.applications.map(&:order_id)
    assert_equal "distribution", payment.applications.first.application_kind
    order.reload
    assert_equal "paid", order.payment_status
    assert_equal 0, order.balance_due_cents
    assert_equal 0, result.credit_cents
  end

  test "pago global repartido entre varios pedidos (ejemplo: $300.000 entre 120/95/180)" do
    a, b, c = honey_orders
    result = register(300_000)

    assert result.ok?
    assert_equal [0, 0, pesos(95_000)], balances(a, b, c)
    assert_equal %w[paid paid partial], [a, b, c].map { |o| o.reload.payment_status }
    assert_equal 3, result.payments.size
    assert_equal pesos(300_000), result.payments.sum(&:amount_cents)
    assert_equal 1, CustomerPayment.count, "una sola transferencia registrada"
    assert_equal 3, Payment.where(customer_payment_id: result.customer_payment.id).count
  end

  test "distribución manual: dejar pedidos sin pagar, cambiar importes y repartir en varios" do
    a, b, c = honey_orders
    result = register(100_000, allocations: { b.id => pesos(60_000), c.id => pesos(30_000) })

    assert result.ok?
    assert_equal [pesos(120_000), pesos(35_000), pesos(150_000)], balances(a, b, c)
    assert_equal pesos(10_000), result.credit_cents, "lo no distribuido queda como saldo a favor"
    assert_equal pesos(10_000), result.customer_payment.unapplied_cents
  end

  test "pago parcial de un pedido y pago exacto" do
    order = make_order(100)
    register(30_000)
    assert_equal "partial", order.reload.payment_status
    assert_equal pesos(70_000), order.balance_due_cents

    result = register(70_000)
    assert result.ok?
    assert_equal "paid", order.reload.payment_status
    assert_equal 0, result.credit_cents
  end

  test "pago superior a la deuda: lo aplicado es la deuda y el excedente queda como saldo a favor" do
    a = make_order(250)
    result = register(300_000)

    assert result.ok?
    assert_equal pesos(250_000), a.reload.amount_paid_cents
    assert_equal pesos(50_000), result.credit_cents
    assert_equal pesos(50_000), CustomerAccounts::ApplyCredit.available_cents(@customer)
  end

  test "un pago sin pedidos pendientes es 100% saldo a favor" do
    result = register(80_000)

    assert result.ok?
    assert_equal pesos(80_000), result.credit_cents
    assert_empty result.customer_payment.applications
  end

  # --- Validaciones --------------------------------------------------------------------

  test "no se puede superar el saldo pendiente de un pedido" do
    a = make_order(10)
    result = register(50, allocations: { a.id => pesos(10_001) })

    assert_not result.ok?
    assert_match(/saldo de \$10\.000/, result.errors.join)
    assert_equal 0, CustomerPayment.count
    assert_equal 0, a.reload.amount_paid_cents
  end

  test "no se puede distribuir más de lo recibido" do
    a = make_order(100)
    b = make_order(100)
    result = register(50_000, allocations: { a.id => pesos(30_000), b.id => pesos(30_000) })

    assert_not result.ok?
    assert_match(/supera el monto recibido/, result.errors.join)
    assert_equal 0, Payment.count
  end

  test "importes negativos o cero y datos inválidos se rechazan" do
    a = make_order(100)

    assert_not register(50_000, allocations: { a.id => -100 }).ok?
    assert_not register(0, allocations: {}).ok?
    assert_not register(-5, allocations: {}).ok?
    assert_not CustomerAccounts::RegisterPayment.call(customer: @customer, user: @admin, amount_cents: "100", paid_on: Date.current, payment_method: "bank_transfer", allocations: {}).ok?
    assert_not CustomerAccounts::RegisterPayment.call(customer: @customer, user: @admin, amount_cents: 1000, paid_on: Date.current, payment_method: "efectivo-falso", allocations: {}).ok?
    assert_not CustomerAccounts::RegisterPayment.call(customer: @customer, user: @admin, amount_cents: 1000, paid_on: nil, payment_method: "bank_transfer", allocations: {}).ok?
    assert_not CustomerAccounts::RegisterPayment.call(customer: @customer, user: @admin, amount_cents: 1000, paid_on: Date.current + 1, payment_method: "bank_transfer", allocations: {}).ok?
    assert_not CustomerAccounts::RegisterPayment.call(customer: @customer, user: nil, amount_cents: 1000, paid_on: Date.current, payment_method: "bank_transfer", allocations: {}).ok?
    assert_not CustomerAccounts::RegisterPayment.call(customer: @customer, user: @admin, amount_cents: 1000, paid_on: Date.current, payment_method: "bank_transfer", allocations: { "x" => 100 }).ok?
    assert_equal 0, CustomerPayment.count
    assert_equal 0, Payment.count
  end

  test "no se pueden aplicar pagos a pedidos de otro cliente ni inexistentes" do
    mine = make_order(10)
    foreign = make_order(10, customer: @other_customer)

    result = register(10_000, allocations: { foreign.id => pesos(10_000) })
    assert_not result.ok?
    assert_match(/no pertenece a este cliente/, result.errors.join)
    assert_equal 0, foreign.reload.amount_paid_cents

    assert_not register(10_000, allocations: { 99_999_999 => pesos(10_000) }).ok?
    assert_not register(10_000, allocations: { mine.id => pesos(5_000), foreign.id => pesos(5_000) }).ok?, "un solo pedido ajeno invalida todo el pago"
    assert_equal 0, mine.reload.amount_paid_cents
    assert_equal 0, CustomerPayment.count
  end

  test "no se asignan pagos a pedidos cancelados" do
    canceled = make_order(10, status: "canceled")
    result = register(10_000, allocations: { canceled.id => pesos(10_000) })

    assert_not result.ok?
    assert_match(/cancelado/, result.errors.join)
    assert_equal 0, canceled.reload.amount_paid_cents
  end

  test "todo o nada: si una aplicación falla no queda ningún registro a medias" do
    a = make_order(10)
    b = make_order(10)
    result = register(30_000, allocations: { a.id => pesos(10_000), b.id => pesos(10_001) })

    assert_not result.ok?
    assert_equal 0, CustomerPayment.count
    assert_equal 0, Payment.count
    assert_equal [0, 0], [a, b].map { |o| o.reload.amount_paid_cents }
  end

  # --- Duplicados y consistencia -------------------------------------------------------------

  test "protección ante duplicados: el mismo request_token registra el pago una sola vez" do
    a = make_order(100)
    token = SecureRandom.uuid

    first = register(40_000, token: token)
    second = register(40_000, token: token)
    third = register(40_000, token: token)

    assert first.ok?
    assert_not first.duplicate?
    assert second.ok?
    assert second.duplicate?
    assert third.duplicate?
    assert_equal first.customer_payment.id, second.customer_payment.id
    assert_equal 1, CustomerPayment.count
    assert_equal pesos(40_000), a.reload.amount_paid_cents, "no se aplicó dos veces"
  end

  test "ausencia de doble contabilización: la transferencia cuenta una vez, sus aplicaciones no suman ingresos" do
    a, b, c = honey_orders
    individual = a.payments.create!(amount_cents: pesos(20_000), paid_at: Time.current, payment_method: "cash_on_delivery")
    register(300_000)
    summary = CustomerAccounts::Summary.new(@customer)

    assert_equal pesos(320_000), summary.received_cents, "20.000 individual + 300.000 global, una vez cada uno"
    assert_equal 4, Payment.count, "1 individual + 3 aplicaciones"
    assert_equal pesos(320_000), Payment.active.sum(:amount_cents), "pagos aplicados a pedidos"
    assert_equal pesos(300_000), CustomerPayment.active.sum(:amount_cents)
    assert_equal individual.amount_cents + CustomerPayment.sum(:amount_cents), summary.received_cents
  end

  test "el saldo del pedido sale de la lógica existente (Order#recalculate_payment_state!)" do
    a = make_order(100)
    register(40_000)

    assert_equal a.payments.active.sum(:amount_cents), a.reload.amount_paid_cents
    a.recalculate_payment_state!
    assert_equal pesos(40_000), a.reload.amount_paid_cents
    assert_equal "partial", a.payment_status
  end

  test "pagos históricos: no se alteran al registrar pagos globales" do
    a = make_order(100)
    historic = a.payments.create!(amount_cents: pesos(30_000), paid_at: Time.zone.local(2026, 9, 1), payment_method: "cash_on_delivery", note: "viejo")
    snapshot = historic.reload.attributes

    register(50_000)

    assert_equal snapshot, historic.reload.attributes
    assert_equal pesos(80_000), a.reload.amount_paid_cents
  end

  test "el pago global guarda usuario, fecha efectiva, fecha real de registro, medio, referencia y comentario" do
    make_order(10)
    result = register(10_000, paid_on: Date.current - 2, method: "cash_on_delivery", reference: "TRF-9981", note: "Transferencia semanal")
    payment = result.customer_payment

    assert_equal @admin, payment.user
    assert_equal Date.current - 2, payment.paid_on
    assert_in_delta Time.current.to_f, payment.created_at.to_f, 5
    assert_equal "cash_on_delivery", payment.payment_method
    assert_equal "TRF-9981", payment.reference
    assert_equal "Transferencia semanal", payment.note
    application = payment.applications.first
    assert_equal @admin, application.user
    assert_match(/TRF-9981/, application.note)
  end
end
