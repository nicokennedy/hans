require "test_helper"
require_relative "../../support/customer_account_helpers"
require_relative "../../support/retail_helpers"
require_relative "../../support/finance_helpers"

# Administración → Resumen: ventas, resultado económico simplificado y flujo de caja.
class Finance::PeriodResultTest < ActiveSupport::TestCase
  include CustomerAccountHelpers
  include RetailHelpers
  include FinanceHelpers

  TODAY = Date.new(2026, 11, 11)
  OCT = Date.new(2026, 10, 1)..Date.new(2026, 10, 31)

  def setup
    setup_account
    setup_retail
    setup_finance # @admin y @category (de gastos) quedan de Administración
    travel_to Time.zone.local(2026, 11, 11, 12)
  end

  def teardown
    travel_back
  end

  def result(month: 10, year: 2026, from: nil, to: nil)
    Finance::PeriodResult.new(Finance::Summary.new(year: year, month: month, from: from, to: to, today: TODAY))
  end

  def pay_order(order, amount, paid_on)
    order.payments.create!(amount_cents: pesos(amount), paid_at: paid_on.in_time_zone.change(hour: 23, min: 30), payment_method: "cash_on_delivery")
  end

  def retail_order(amount, delivery_date: Date.new(2026, 10, 18), **attributes)
    create_retail(attributes: { delivery_date: delivery_date.iso8601 }.merge(attributes), items: [manual_row("Box", 1, amount)])
  end

  def pay_retail_on(order, amount, paid_on)
    result = Retail::RegisterPayment.call(order: order, user: @admin, amount: amount, paid_at: paid_on, payment_method: "transfer")
    raise result.errors.inspect unless result.ok?

    result
  end

  # --- Ventas mayoristas ---------------------------------------------------------------------------------

  test "mayoristas: facturado por fecha de entrega, sin cancelados, igual que el resumen de Pedidos" do
    make_order(100, delivery_date: Date.new(2026, 10, 5))
    make_order(50, delivery_date: Date.new(2026, 10, 31))
    make_order(70, delivery_date: Date.new(2026, 10, 12), status: "canceled")
    make_order(999, delivery_date: Date.new(2026, 11, 2))
    make_order(888, delivery_date: Date.new(2026, 9, 30))

    w = result.wholesale
    assert_equal 2, w.orders_count
    assert_equal pesos(150_000), w.invoiced_cents
    assert_equal 1, w.canceled_count

    existing = Collections::OrdersSummary.new(Orders::ListFilters.new({ delivery_date: "2026-10-01", delivery_date_to: "2026-10-31" }).apply(Order.all))
    assert_equal [existing.orders_count, existing.invoiced_cents], [w.orders_count, w.invoiced_cents], "mismo criterio que Pedidos filtrado por el mes"
  end

  test "mayoristas: cobrado por fecha real de pago, aunque el pedido sea de otro mes; parciales sumados una vez" do
    september = make_order(100, delivery_date: Date.new(2026, 9, 28))
    october = make_order(80, delivery_date: Date.new(2026, 10, 10))
    pay_order(september, 30_000, Date.new(2026, 9, 28))  # septiembre
    pay_order(september, 70_000, Date.new(2026, 10, 2))  # octubre, pedido de septiembre
    pay_order(october, 20_000, Date.new(2026, 10, 31))   # 23:30 hora argentina: sigue siendo octubre
    pay_order(october, 10_000, Date.new(2026, 11, 3))    # noviembre

    assert_equal pesos(90_000), result.wholesale.collected_cents
    assert_equal pesos(30_000), result(month: 9).wholesale.collected_cents
    assert_equal pesos(10_000), result(month: 11).wholesale.collected_cents
  end

  test "mayoristas: un pago de cuenta corriente cuenta una vez y completo (con saldo a favor); los anulados no" do
    a = make_order(120, delivery_date: Date.new(2026, 10, 5))
    b = make_order(95, delivery_date: Date.new(2026, 10, 6))
    register(250_000, paid_on: Date.new(2026, 10, 20))           # cubre a y b, $35.000 a favor
    voided = pay_order(make_order(10, delivery_date: Date.new(2026, 10, 7)), 10_000, Date.new(2026, 10, 8))
    voided.update!(voided_at: Time.current, void_reason: "error")

    assert_equal pesos(250_000), result.wholesale.collected_cents
    assert_equal pesos(10_000), result.wholesale.pending_at_close_cents, "el pedido con el pago anulado sigue debiendo"
    assert_equal [0, 0], [a, b].map { |o| o.reload.balance_due_cents }
  end

  test "mayoristas: pendiente al cierre descuenta solo los pagos hasta el último día del período" do
    order = make_order(100, delivery_date: Date.new(2026, 10, 15))
    pay_order(order, 40_000, Date.new(2026, 10, 20))
    pay_order(order, 60_000, Date.new(2026, 11, 5))
    paid = make_order(30, delivery_date: Date.new(2026, 10, 16))
    pay_order(paid, 30_000, Date.new(2026, 10, 16))

    assert_equal pesos(60_000), result.wholesale.pending_at_close_cents, "al 31/10 faltaban $60.000"
    assert_equal 0, Collections::OrdersSummary.new(Order.where(delivery_date: OCT)).pending_cents, "hoy está saldado"
    assert_not result.open_period?
  end

  test "período en curso: el pendiente a hoy coincide con el pendiente del resumen de Pedidos" do
    order = make_order(100, delivery_date: Date.new(2026, 11, 4))
    pay_order(order, 25_000, Date.new(2026, 11, 5))

    r = result(month: 11)
    assert r.open_period?
    assert_equal Collections::OrdersSummary.new(Order.where(delivery_date: Date.new(2026, 11, 1)..Date.new(2026, 11, 30))).pending_cents, r.wholesale.pending_at_close_cents
    assert_equal pesos(75_000), r.wholesale.pending_at_close_cents
  end

  # --- Ventas minoristas -----------------------------------------------------------------------------------

  test "minoristas: solo confirmados, sin cancelados; envío incluido; cobros por fecha de pago y sin anulados" do
    delivered = retail_order("8.500", shipping: "1.500")
    assert_equal [pesos(8_500), pesos(1_500), pesos(10_000)], [delivered.subtotal_cents, delivered.shipping_cents, delivered.total_cents]
    pay_retail_on(delivered, "4.000", Date.new(2026, 10, 18))
    pay_retail_on(delivered, "6.000", Date.new(2026, 11, 2))
    voided = pay_retail_on(retail_order("3.000"), "3.000", Date.new(2026, 10, 19)).record
    Retail::VoidPayment.call(payment: voided, user: @admin, reason: "error")
    canceled = retail_order("7.000")
    Retail::ChangeStatus.call(order: canceled, to_status: "canceled", user: @admin)
    awaiting = Retail::SaveOrder.call(order: RetailOrder.new, attributes: base_attributes, items: [manual_row("Box", 1, "5.000")], user: nil, source: "store").record
    assert awaiting.confirmation_awaiting?
    september = retail_order("2.000", delivery_date: Date.new(2026, 9, 20))
    pay_retail_on(september, "2.000", Date.new(2026, 10, 1))

    r = result.retail
    assert_equal 2, r.orders_count
    assert_equal pesos(13_000), r.invoiced_cents
    assert_equal [1, 1], [r.canceled_count, r.unconfirmed_count]
    assert_equal pesos(6_000), r.collected_cents, "$4.000 + $2.000 de un pedido de septiembre; el anulado no"
    assert_equal pesos(9_000), r.pending_at_close_cents, "al 31/10: $6.000 + $3.000"

    existing = Collections::OrdersSummary.new(Retail::ListFilters.new({ date_from: "2026-10-01", date_to: "2026-10-31" }).apply(RetailOrder.all))
    assert_equal [existing.orders_count, existing.invoiced_cents], [r.orders_count, r.invoiced_cents]
  end

  # --- Resultado económico -----------------------------------------------------------------------------------

  test "resultado: ventas − compras − gastos del período, con porcentaje sobre ventas" do
    make_order(100, delivery_date: Date.new(2026, 10, 5))
    retail_order("20.000")
    make_purchase(50_000, accrual_on: Date.new(2026, 10, 3))
    make_purchase(99_999, accrual_on: Date.new(2026, 11, 3))
    make_expense(10_000, accrual_on: Date.new(2026, 10, 9))

    r = result
    assert_equal pesos(120_000), r.sales_cents
    assert_equal [pesos(50_000), pesos(10_000), pesos(60_000)], [r.purchases_cents, r.expenses_cents, r.costs_cents]
    assert_equal pesos(60_000), r.result_cents
    assert_equal 50.0, r.result_margin
  end

  test "resultado negativo y mes sin ventas: porcentaje no calculable" do
    make_expense(1_000, accrual_on: Date.new(2026, 8, 9))

    r = result(month: 8)
    assert_equal pesos(-1_000), r.result_cents
    assert_nil r.result_margin
  end

  test "mes sin movimientos: todo en cero" do
    r = result(month: 3)
    values = [r.wholesale.orders_count, r.sales_cents, r.costs_cents, r.result_cents, r.collected_cents, r.paid_cents, r.net_cash_cents, r.wholesale.pending_at_close_cents, r.retail.pending_at_close_cents]
    assert_equal [0] * values.size, values
    assert_nil r.result_margin
  end

  # --- Flujo de caja --------------------------------------------------------------------------------------

  test "flujo: pagos por fecha efectiva separados en compras, gastos y anticipos; cada pago una vez" do
    purchase = make_purchase(100, accrual_on: Date.new(2026, 9, 1))
    expense = make_expense(30, supplier: @supplier, accrual_on: Date.new(2026, 10, 1))
    pay(60, paid_on: Date.new(2026, 10, 5), allocations: { purchase.id => pesos(40), expense.id => pesos(20) }) # un pago, dos imputaciones
    pay(25, paid_on: Date.new(2026, 10, 6), allocations: {})                                                    # anticipo
    pay(60, paid_on: Date.new(2026, 11, 2), allocations: { purchase.id => pesos(60) })                          # noviembre
    no_supplier = make_expense(15, accrual_on: Date.new(2026, 10, 2))
    pay(15, supplier: nil, paid_on: Date.new(2026, 10, 7), allocations: { no_supplier.id => pesos(15) })
    voided = pay(5, paid_on: Date.new(2026, 10, 8), allocations: { expense.id => pesos(5) }).payment
    Finance::VoidPayment.call(payment: voided, user: @admin, reason: "error")

    order = make_order(50, delivery_date: Date.new(2026, 9, 10))
    pay_order(order, 50_000, Date.new(2026, 10, 3))
    pay_retail_on(retail_order("8.000"), "8.000", Date.new(2026, 10, 18))

    r = result
    assert_equal [pesos(40), pesos(35), pesos(25)], [r.paid_purchases_cents, r.paid_expenses_cents, r.paid_advances_cents]
    assert_equal pesos(100), r.paid_cents
    assert_equal Finance::Summary.new(year: 2026, month: 10, today: TODAY).paid_in_period_cents, r.paid_cents, "igual al Pagado del resumen"
    assert_equal pesos(58_000), r.collected_cents
    assert_equal pesos(58_000) - pesos(100), r.net_cash_cents
  end

  test "flujo: un anticipo aplicado después pasa a compras en el período del pago original" do
    pay(30, paid_on: Date.new(2026, 10, 6), allocations: {})
    obligation = make_purchase(30, accrual_on: Date.new(2026, 11, 1))
    Finance::ApplyAdvance.call(supplier: @supplier, user: @admin, allocations: { obligation.id => pesos(30) })

    r = result
    assert_equal [pesos(30), 0, 0], [r.paid_purchases_cents, r.paid_expenses_cents, r.paid_advances_cents]
    assert_equal 0, result(month: 11).paid_cents, "aplicar un anticipo no es un pago nuevo"
  end

  test "compras y gastos con pagos parciales: el resultado usa el devengado completo, el flujo solo lo pagado" do
    purchase = make_purchase(100, accrual_on: Date.new(2026, 10, 1))
    expense = make_expense(50, accrual_on: Date.new(2026, 10, 1))
    pay(40, paid_on: Date.new(2026, 10, 10), allocations: { purchase.id => pesos(40) })
    pay(10, supplier: nil, paid_on: Date.new(2026, 10, 11), allocations: { expense.id => pesos(10) })

    r = result
    assert_equal pesos(150), r.costs_cents
    assert_equal pesos(50), r.paid_cents
    assert_equal [pesos(40), pesos(10)], [r.paid_purchases_cents, r.paid_expenses_cents]
  end

  # --- Período ---------------------------------------------------------------------------------------------

  test "cambio de período: mes, año completo y rango personalizado" do
    make_order(10, delivery_date: Date.new(2026, 10, 5))
    make_order(20, delivery_date: Date.new(2026, 10, 25))
    make_order(40, delivery_date: Date.new(2026, 11, 4))

    assert_equal pesos(30_000), result.sales_cents
    assert_equal pesos(40_000), result(month: 11).sales_cents
    assert_equal pesos(70_000), result(month: "all").sales_cents
    custom = result(from: "2026-10-20", to: "2026-11-05")
    assert custom.summary.custom?
    assert_equal pesos(60_000), custom.sales_cents
    assert_equal "Del 20/10/2026 al 05/11/2026", custom.summary.period_label
    assert_equal pesos(60_000), result(from: "2026-11-05", to: "2026-10-20").sales_cents, "el rango invertido se ordena"
    assert_not result(from: "2026-10-20", to: "basura").summary.custom?, "un rango incompleto o inválido se ignora"
  end
end
