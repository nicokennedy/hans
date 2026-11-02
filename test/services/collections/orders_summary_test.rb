require "test_helper"
require_relative "../../support/customer_account_helpers"
require_relative "../../support/retail_helpers"

# Resumen financiero de los listados de Pedidos y Pedidos Minoristas: cantidad, facturado,
# cobrado (solo lo imputado a esos pedidos) y pendiente (saldos positivos), sin cancelados.
class Collections::OrdersSummaryTest < ActiveSupport::TestCase
  include CustomerAccountHelpers
  include RetailHelpers

  def setup
    setup_account
    setup_retail
  end

  def summary_of(scope)
    s = Collections::OrdersSummary.new(scope)
    [s.orders_count, s.invoiced_cents, s.collected_cents, s.pending_cents, s.canceled_count]
  end

  test "mayoristas: cantidad, facturado, cobrado y pendiente con pagos totales, parciales y sin pagos" do
    paid = make_order(10)
    paid.payments.create!(amount_cents: pesos(10_000), paid_at: Time.current, payment_method: "cash_on_delivery")
    partial = make_order(20)
    partial.payments.create!(amount_cents: pesos(5_000), paid_at: Time.current, payment_method: "cash_on_delivery")
    make_order(30)

    assert_equal [3, pesos(60_000), pesos(15_000), pesos(45_000), 0], summary_of(Order.where(customer: @customer))
  end

  test "mayoristas: un pago de cuenta corriente cuenta solo por lo imputado, nunca el saldo a favor ni dos veces" do
    a, b, c = honey_orders # $120.000 + $95.000 + $180.000
    register(300_000)      # cubre a y b, $85.000 a c
    register(50_000, orders: [])  # sin imputar: queda todo como saldo a favor

    assert_equal pesos(350_000), CustomerPayment.active.where(customer: @customer).sum(:amount_cents)
    assert_equal [3, pesos(395_000), pesos(300_000), pesos(95_000), 0], summary_of(Order.where(id: [a, b, c]))

    # Solo los pedidos del período: la parte imputada a c no se suma al resumen de a y b.
    assert_equal [2, pesos(215_000), pesos(215_000), 0, 0], summary_of(Order.where(id: [a, b]))
  end

  test "mayoristas: pago individual + aplicación de cuenta corriente al mismo pedido se suman una vez cada uno" do
    order = make_order(100)
    order.payments.create!(amount_cents: pesos(30_000), paid_at: Time.current, payment_method: "cash_on_delivery")
    register(50_000, allocations: { order.id => pesos(50_000) })

    assert_equal [1, pesos(100_000), pesos(80_000), pesos(20_000), 0], summary_of(Order.where(id: order))
  end

  test "mayoristas: los cancelados no cuentan en ningún indicador y se informan aparte" do
    make_order(10)
    make_order(40, status: "canceled")

    assert_equal [1, pesos(10_000), 0, pesos(10_000), 1], summary_of(Order.where(customer: @customer))
  end

  test "mayoristas: un pedido cuyo total bajó por debajo de lo pagado no deja pendiente negativo" do
    over = make_order(10)
    over.payments.create!(amount_cents: pesos(10_000), paid_at: Time.current, payment_method: "cash_on_delivery")
    over.order_items.first.update!(quantity: 6)
    over.reload.save!
    make_order(20)

    assert_equal pesos(6_000), over.reload.total_cents
    assert_equal [2, pesos(26_000), pesos(10_000), pesos(20_000), 0], summary_of(Order.where(customer: @customer))
  end

  test "minoristas: productos manuales y de catálogo, pagos parciales, anulados, excedentes y cancelados" do
    manual = create_retail(items: [manual_row("OTROS", 1, "15.000")])
    pay_retail(manual, "15.000")
    mixed = create_retail(items: [product_row(@mini, 2, "500"), manual_row("Torta especial", 1, "9.000")]) # $10.000
    pay_retail(mixed, "4.000")
    voided = pay_retail(mixed, "1.000").record
    Retail::VoidPayment.call(payment: voided, user: @admin, reason: "error")
    lowered = create_retail(items: [manual_row("Box", 1, "8.000")])
    pay_retail(lowered, "8.000")
    update_retail(lowered, items: [manual_row("Box", 1, "5.000")]) # queda $3.000 de excedente
    canceled = create_retail(items: [manual_row("Box", 1, "7.000")])
    Retail::ChangeStatus.call(order: canceled, to_status: "canceled", user: @admin)

    assert_equal [3, pesos(30_000), pesos(27_000), pesos(6_000), 1], summary_of(RetailOrder.all)
  end

  test "sin resultados: todo en cero" do
    assert_equal [0, 0, 0, 0, 0], summary_of(Order.none)
    assert_equal [0, 0, 0, 0, 0], summary_of(RetailOrder.where(id: -1))
  end

  test "ignora orden, paginación e includes del scope: resume todos los pedidos filtrados" do
    3.times { |i| make_order(10 + i) }
    paged = Order.includes(:customer).where(customer: @customer).order(created_at: :desc).limit(1).offset(1)

    assert_equal [3, pesos(33_000), 0, pesos(33_000), 0], summary_of(paged)
  end

  test "calcular el resumen no modifica pedidos, pagos ni stock" do
    order = make_order(10)
    order.payments.create!(amount_cents: pesos(4_000), paid_at: Time.current, payment_method: "cash_on_delivery")
    create_retail(items: [manual_row("OTROS", 1, "1.000")])
    snapshot = -> { [Order.order(:id).pluck(:id, :total_cents, :amount_paid_cents, :payment_status, :updated_at), Payment.count, CustomerPayment.count,
                     RetailOrder.order(:id).pluck(:id, :total_cents, :amount_paid_cents, :updated_at), RetailOrderPayment.count, StockMovement.count] }
    before = snapshot.call

    Collections::OrdersSummary.new(Order.all)
    Collections::OrdersSummary.new(RetailOrder.all)

    assert_equal before, snapshot.call
  end
end
