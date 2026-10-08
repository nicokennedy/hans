require "test_helper"
require_relative "../../support/customer_account_helpers"

class CustomerAccounts::SummaryTest < ActiveSupport::TestCase
  include CustomerAccountHelpers

  def setup
    setup_account
  end

  def summary(**options)
    CustomerAccounts::Summary.new(@customer, **options)
  end

  test "resumen: pedidos, facturado, aplicado, pendiente, saldo a favor y recibido" do
    a, b, c = honey_orders
    a.payments.create!(amount_cents: pesos(20_000), paid_at: Time.current, payment_method: "cash_on_delivery") # individual
    register(300_000) # 100.000 al primer saldo + 95.000 + 105.000 (total pendiente 375.000)
    register(100_000, allocations: {}) # todo crédito
    s = summary

    assert_equal 3, s.orders_count
    assert_equal pesos(395_000), s.invoiced_cents
    assert_equal pesos(320_000), s.applied_cents
    assert_equal pesos(75_000), s.pending_cents
    assert_equal pesos(100_000), s.credit_cents
    assert_equal pesos(420_000), s.received_cents, "20 individual + 300 + 100 globales"
  end

  test "consistencia: la deuda del cliente coincide con los saldos de los pedidos y el crédito con lo no aplicado" do
    a, b, c = honey_orders
    register(150_000)
    register(10_000, allocations: {}) # crédito 10.000
    b.payments.create!(amount_cents: pesos(5_000), paid_at: Time.current, payment_method: "cash_on_delivery")
    s = summary

    assert_equal [a, b, c].sum { |o| [o.reload.balance_due_cents, 0].max }, s.pending_cents
    assert_equal pesos(10_000), s.credit_cents
    assert_equal s.pending_cents - s.credit_cents, s.account_balance_cents
    # conservación del dinero: todo lo recibido está aplicado a algún pedido o es saldo a favor
    all_applied = Payment.active.joins(:order).where(orders: { customer_id: @customer.id }).sum(:amount_cents)
    assert_equal s.received_cents, all_applied + s.credit_cents
  end

  test "los pedidos cancelados no son deuda ni facturado; lo ya pagado sobre ellos se informa aparte y no se mueve" do
    a = make_order(100)
    canceled = make_order(50)
    canceled.payments.create!(amount_cents: pesos(20_000), paid_at: Time.current, payment_method: "cash_on_delivery")
    canceled.update!(status: "canceled")
    s = summary

    assert_equal 1, s.orders_count
    assert_equal 1, s.canceled_orders_count
    assert_equal pesos(100_000), s.invoiced_cents
    assert_equal pesos(100_000), s.pending_cents
    assert_equal pesos(20_000), s.canceled_paid_cents
    assert_equal pesos(20_000), canceled.reload.amount_paid_cents, "no se ajusta nada solo"
    assert_equal pesos(20_000), s.received_cents, "es plata realmente recibida"
    assert_not_includes CustomerAccounts::Distribution.pending_orders(@customer).map(&:id), canceled.id
  end

  test "cancelar un pedido después de un pago global: el pago y sus aplicaciones se conservan, sin inventar movimientos" do
    a, b, c = honey_orders
    payment = register(300_000).customer_payment
    movements = [CustomerPayment.count, Payment.count]

    b.update!(status: "canceled")

    assert_equal movements, [CustomerPayment.count, Payment.count]
    assert_equal pesos(95_000), b.reload.amount_paid_cents
    s = summary
    assert_equal pesos(95_000), s.canceled_paid_cents
    assert_equal pesos(95_000), s.pending_cents, "solo el saldo del tercer pedido"
    assert_equal 0, s.credit_cents
    assert_equal pesos(300_000), s.received_cents
    # y se puede anular el pago: revierte también la aplicación al pedido cancelado
    assert CustomerAccounts::VoidPayment.call(customer_payment: payment, user: @admin, reason: "prueba").ok?
    assert_equal 0, b.reload.amount_paid_cents
  end

  test "modificar el importe de un pedido después de recibir un pago: el pago no se toca y el excedente se informa" do
    a = make_order(100)
    register(100_000)
    assert_equal "paid", a.reload.payment_status

    # el pedido sube de $100.000 a $120.000: queda un saldo real de $20.000
    a.order_items.first.update!(quantity: 120)
    a.reload.save!
    assert_equal pesos(120_000), a.total_cents
    assert_equal pesos(20_000), a.balance_due_cents
    assert_equal "partial", a.payment_status
    assert_equal pesos(20_000), summary.pending_cents

    # el pedido baja a $80.000: el pago ($100.000) ya no cabe; no se mueve nada automáticamente
    a.order_items.first.update!(quantity: 80)
    a.reload.save!
    assert_equal pesos(100_000), a.amount_paid_cents
    assert_equal(-pesos(20_000), a.balance_due_cents)
    s = summary
    assert_equal 0, s.pending_cents, "un excedente nunca resta deuda de otros pedidos"
    assert_equal pesos(20_000), s.overpaid_cents
    assert_equal 0, s.credit_cents, "no se convierte solo en saldo a favor"
  end

  test "filtros de pedidos: todos, con saldo pendiente, pagados y rango de fechas; orden por entrega ascendente" do
    a, b, c = honey_orders
    register(120_000)
    assert_equal %w[paid pending pending], [a, b, c].map { |o| o.reload.payment_status }

    assert_equal [a.id, b.id, c.id], summary.filtered_orders.map(&:id)
    assert_equal [b.id, c.id], summary(filter: "pending").filtered_orders.map(&:id)
    assert_equal [a.id], summary(filter: "paid").filtered_orders.map(&:id)
    assert_equal [b.id], summary(from: "2026-10-06", to: "2026-10-06").filtered_orders.map(&:id)
    assert_equal [b.id, c.id], summary(filter: "pending", from: "2026-10-06").filtered_orders.map(&:id)
    assert_equal [a.id, b.id, c.id], summary(filter: "inválido").filtered_orders.map(&:id)
    assert summary(from: "basura").invalid_dates?
  end

  test "el historial muestra cada pago una sola vez: las aplicaciones van dentro del pago global" do
    a, b, c = honey_orders
    individual = a.payments.create!(amount_cents: pesos(5_000), paid_at: Time.current, payment_method: "cash_on_delivery")
    global = register(300_000).customer_payment
    global_credit = register(10_000, allocations: {}).customer_payment

    history = summary.history
    records = history.map { |entry| entry[:record] }

    assert_equal 3, history.size, "1 individual + 2 globales; las 3 aplicaciones no son entradas aparte"
    assert_includes records, individual
    assert_includes records, global
    assert_includes records, global_credit
    assert_equal 3, history.find { |e| e[:record] == global }[:record].applications.size
    assert_equal pesos(5_000 + 300_000 + 10_000), history.sum { |e| e[:record].amount_cents }, "los totales no duplican las aplicaciones"
    assert_equal history.map { |e| [e[:date], e[:sort]] }.sort.reverse, history.map { |e| [e[:date], e[:sort]] }
  end

  test "los pagos de cuenta corriente anulados siguen en el historial pero no suman" do
    make_order(10)
    payment = register(10_000).customer_payment
    CustomerAccounts::VoidPayment.call(customer_payment: payment, user: @admin, reason: "error")

    s = summary
    assert_includes s.history.map { |e| e[:record] }, payment
    assert_equal 0, s.received_cents
    assert_equal pesos(10_000), s.pending_cents
  end

  test "compatibilidad: un cliente con solo pagos históricos por pedido ve exactamente esos importes" do
    a = make_order(100)
    b = make_order(50)
    a.payments.create!(amount_cents: pesos(100_000), paid_at: Time.zone.local(2026, 9, 1), payment_method: "cash_on_delivery")
    b.payments.create!(amount_cents: pesos(10_000), paid_at: Time.zone.local(2026, 9, 2), payment_method: "bank_transfer")
    s = summary

    assert_equal pesos(150_000), s.invoiced_cents
    assert_equal pesos(110_000), s.applied_cents
    assert_equal pesos(40_000), s.pending_cents
    assert_equal 0, s.credit_cents
    assert_equal pesos(110_000), s.received_cents
    assert_equal 2, s.history.size
    assert s.history.all? { |e| e[:kind] == :individual }
  end

  test "el resumen de un cliente no incluye datos de otros clientes" do
    make_order(10)
    make_order(99, customer: @other_customer)
    register(50_000, customer: @other_customer, orders: [])

    s = summary
    assert_equal pesos(10_000), s.invoiced_cents
    assert_equal 0, s.credit_cents
    assert_equal 0, s.received_cents
    assert_equal [], s.history
  end
end
