require "test_helper"
require_relative "../../support/retail_helpers"

# Resumen (Cantidad de pedidos, Facturado, Cobrado, Pendiente) arriba de los listados de
# Pedidos y Pedidos Minoristas: responde a los filtros, cubre todas las páginas y no altera datos.
class Admin::OrdersSummaryTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include RetailHelpers

  D9 = Date.new(2026, 10, 9)
  D10 = Date.new(2026, 10, 10)
  D12 = Date.new(2026, 10, 12)

  setup do
    setup_retail
    @cook = User.create!(email: "summary-cook-#{rand(1_000_000)}@example.com", password: "password123", role: "production")
    @honey = Customer.create!(name: "Honey #{rand(1_000_000)}", active: true)
    @other = Customer.create!(name: "Otro #{rand(1_000_000)}", active: true)
    @rogel = make_product("Rogel resumen #{rand(1_000_000)}", 50_000)
    sign_in @admin
  end

  # Pedido mayorista de `units` x $500, con `paid` pesos pagados.
  def order(customer, date, units: 2, paid: 0, status: nil)
    o = Order.new(customer: customer, delivery_date: date, created_by_admin: true, payment_method_selected: "cash_on_delivery")
    o.status = status if status
    o.order_items.build(product: @rogel, quantity: units)
    o.save!
    o.payments.create!(amount_cents: pesos(paid), paid_at: Time.current, payment_method: "cash_on_delivery") if paid.positive?
    o.reload
  end

  def summary
    %w[count invoiced collected pending].map { |k| css_select("#orders-summary-#{k}").first&.text&.strip }
  end

  # --- Pedidos (mayoristas) ---

  test "Pedidos: el resumen aparece entre los filtros y el listado, con el mismo diseño que el de Clientes" do
    order(@honey, D9, units: 4, paid: 500)

    get admin_orders_path
    assert_response :success
    assert_equal ["1", "$2.000", "$500", "$1.500"], summary
    assert_select "#orders-summary.product-card h2.fs-5.fw-bold", text: "Resumen del período (Todos)"
    assert_select "#orders-summary .row .col-6.col-md-3 .fw-bold.fs-5", count: 4 # 2x2 en celular, una fila desde tablet
    assert_select "#orders-summary .text-muted.small", text: "Cantidad de pedidos"
    assert response.body.index('id="orders-filters"') < response.body.index('id="orders-summary"')
    assert response.body.index('id="orders-summary"') < response.body.index('id="orders-count"')
  end

  test "Pedidos: cliente + rango de fechas + estado de pago se aplican juntos y Limpiar vuelve al total" do
    order(@honey, D9, paid: 0)
    order(@honey, D10, units: 4, paid: 500)
    order(@honey, D12, paid: 1_000)
    order(@other, D10, paid: 0)

    get admin_orders_path, params: { delivery_date: D9.iso8601, delivery_date_to: D10.iso8601 }
    assert_equal ["3", "$4.000", "$500", "$3.500"], summary
    assert_select "#orders-summary h2", text: "Resumen del período (09/10/2026 – 10/10/2026)"

    get admin_orders_path, params: { customer_id: @honey.id, delivery_date: D9.iso8601, delivery_date_to: D10.iso8601 }
    assert_equal ["2", "$3.000", "$500", "$2.500"], summary

    get admin_orders_path, params: { customer_id: @honey.id, delivery_date: D9.iso8601, delivery_date_to: D12.iso8601, payment_status_filter: "partial" }
    assert_equal ["1", "$2.000", "$500", "$1.500"], summary

    # el estado de pago queda guardado en la sesión (comportamiento existente): el resumen lo respeta igual que el listado
    get admin_orders_path, params: { delivery_date: D10.iso8601 }
    assert_equal ["1", "$2.000", "$500", "$1.500"], summary

    get admin_orders_path, params: { delivery_date: D10.iso8601, payment_status_filter: "all" } # solo "desde": ese día
    assert_equal ["2", "$3.000", "$500", "$2.500"], summary

    get admin_orders_path, params: { delivery_date_to: D9.iso8601 } # solo "hasta": hasta ese día
    assert_equal ["1", "$1.000", "$0", "$1.000"], summary
    assert_select "#orders-summary h2", text: "Resumen del período (hasta 09/10/2026)"

    get css_select("#orders-clear-filters").first["href"]
    assert_equal ["4", "$5.000", "$1.500", "$3.500"], summary
  end

  test "Pedidos: el rango de fechas filtra el listado y viaja en los links al pedido" do
    a = order(@honey, D9)
    order(@honey, D12)

    get admin_orders_path, params: { delivery_date: D9.iso8601, delivery_date_to: D10.iso8601 }
    assert_select "a[href=?]", admin_order_path(a, delivery_date: D9.iso8601, delivery_date_to: D10.iso8601)
    assert_select "#orders-count", text: /1 pedido · filtrado/
    assert_select "#orders-filters input[name=delivery_date_to][value=?]", D10.iso8601
  end

  test "Pedidos: con paginación, el resumen suma todos los pedidos filtrados y no solo la página" do
    55.times { order(@honey, D9, units: 1, paid: 100) }

    get admin_orders_path, params: { customer_id: @honey.id, page: 2 }
    assert_select "#orders-pagination", text: /Página 2 de 2/
    assert_equal ["55", "$27.500", "$5.500", "$22.000"], summary
  end

  test "Pedidos: los cancelados no suman y se aclara cuántos quedaron afuera" do
    order(@honey, D9, paid: 1_000)
    order(@honey, D9, units: 10, status: "canceled")

    get admin_orders_path
    assert_equal ["1", "$1.000", "$1.000", "$0"], summary
    assert_select "#orders-summary-canceled", text: /1 pedido cancelado no incluido/
  end

  test "Pedidos: sin resultados muestra 0 pedidos y $0" do
    order(@honey, D9)

    get admin_orders_path, params: { delivery_date: Date.new(2030, 1, 1).iso8601 }
    assert_equal ["0", "$0", "$0", "$0"], summary
    assert_select "#orders-summary-canceled", count: 0
  end

  test "Pedidos: producción ve el listado pero no el resumen con importes" do
    order(@honey, D9, paid: 500)
    sign_out @admin
    sign_in @cook

    get admin_orders_path
    assert_response :success
    assert_select "#orders-summary", count: 0
  end

  # --- Pedidos Minoristas ---

  test "Minoristas: resumen con productos manuales y de catálogo, filtros combinados y Limpiar" do
    a = create_retail(attributes: { buyer_name: "Ana", delivery_date: D9.iso8601 }, items: [manual_row("OTROS", 1, "10.000")])
    pay_retail(a, "10.000")
    b = create_retail(attributes: { buyer_name: "Ana", delivery_date: D10.iso8601, delivery_kind: "delivery" }, items: [product_row(@mini, 2, "500"), manual_row("Torta", 1, "3.000")])
    pay_retail(b, "1.000")
    create_retail(attributes: { buyer_name: "Beto", delivery_date: D12.iso8601 }, items: [manual_row("OTROS", 1, "5.000")])

    get admin_retail_orders_path
    assert_response :success
    assert_equal ["3", "$19.000", "$11.000", "$8.000"], summary
    assert response.body.index('id="retail-filters"') < response.body.index('id="orders-summary"')

    get admin_retail_orders_path, params: { date_from: D9.iso8601, date_to: D10.iso8601, buyer: "ana", payment_status: "partial" }
    assert_equal ["1", "$4.000", "$1.000", "$3.000"], summary

    get admin_retail_orders_path, params: { date_from: D9.iso8601, date_to: D12.iso8601, kind: "pickup" }
    assert_equal ["2", "$15.000", "$10.000", "$5.000"], summary
    assert_select "#orders-summary h2", text: "Resumen del período (09/10/2026 – 12/10/2026)"

    get admin_retail_orders_path
    assert_equal ["3", "$19.000", "$11.000", "$8.000"], summary
  end

  test "Minoristas: paginación, cancelados y sin resultados" do
    52.times { |i| pay_retail(create_retail(attributes: { buyer_name: "Cliente #{i}", delivery_date: D9.iso8601 }, items: [manual_row("OTROS", 1, "1.000")]), "500") }
    canceled = create_retail(attributes: { delivery_date: D9.iso8601 }, items: [manual_row("OTROS", 1, "9.000")])
    Retail::ChangeStatus.call(order: canceled, to_status: "canceled", user: @admin)

    get admin_retail_orders_path, params: { page: 2 }
    assert_select "#pagination", text: /Página 2 de 2/
    assert_equal ["52", "$52.000", "$26.000", "$26.000"], summary
    assert_select "#orders-summary-canceled", text: /1 pedido cancelado no incluido/

    get admin_retail_orders_path, params: { buyer: "nadie-coincide" }
    assert_equal ["0", "$0", "$0", "$0"], summary
  end

  test "Minoristas: los pedidos de la tienda sin confirmar no suman y se aclara cuántos quedaron afuera" do
    pay_retail(create_retail(attributes: { delivery_date: D9.iso8601 }, items: [manual_row("OTROS", 1, "2.000")]), "2.000")
    Retail::SaveOrder.call(order: RetailOrder.new, attributes: base_attributes(delivery_date: D9.iso8601), items: [manual_row("Box", 1, "9.000")], user: nil, source: "store")

    get admin_retail_orders_path
    assert_equal ["1", "$2.000", "$2.000", "$0"], summary
    assert_select "#orders-summary-awaiting", text: /1 pedido pendiente de confirmación no incluido/
    assert_select "#orders-summary-rejected", count: 0
  end

  test "ver los listados con el resumen no modifica pedidos, pagos ni stock" do
    order(@honey, D9, paid: 500)
    pay_retail(create_retail(items: [manual_row("OTROS", 1, "1.000")]), "1.000")
    snapshot = -> { [Order.order(:id).pluck(:id, :total_cents, :amount_paid_cents, :payment_status, :updated_at), Payment.count,
                     RetailOrder.order(:id).pluck(:id, :total_cents, :amount_paid_cents, :updated_at), RetailOrderPayment.count, StockMovement.count] }
    before = snapshot.call

    get admin_orders_path, params: { delivery_date: D9.iso8601, delivery_date_to: D12.iso8601 }
    get admin_retail_orders_path, params: { date_from: D9.iso8601, date_to: D12.iso8601 }

    assert_equal before, snapshot.call
  end
end
