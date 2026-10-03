require "test_helper"

# Impresión masiva de remitos por fecha de entrega. El armado de hojas A4 y el
# PDF viven en el navegador (ver test/javascript/); acá se cubre lo que decide
# el servidor: qué pedidos entran, en qué orden, con qué datos y quién puede.
class Admin::OrdersReceiptsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  DATE = Date.new(2026, 10, 3)

  setup do
    @admin = User.create!(email: "receipts-admin@example.com", password: "password123", role: "admin")
    @production = User.create!(email: "receipts-production@example.com", password: "password123", role: "production")

    category = Category.create!(name: "Cafe ReceiptsTest", position: 1, active: true)
    @products = (1..9).map do |i|
      Product.create!(name: "Producto remito #{i}", category: category, price_cents: 1000 * i, cost_cents: 100, active: true, position: i)
    end

    @zeta = Customer.create!(name: "Zeta Cafe", active: true)
    @alfa = Customer.create!(name: "Alfa Cafe", active: true)
    @beta = Customer.create!(name: "Beta Cafe", active: true)
  end

  def build_order(customer, date: DATE, items: 2, status: "received", comment: nil)
    order = Order.new(customer: customer, delivery_date: date, status: status, created_by_admin: true, customer_comment: comment)
    @products.first(items).each_with_index { |product, i| order.order_items.build(product: product, quantity: i + 1) }
    order.save!
    order
  end

  def get_receipts(date = DATE)
    get receipts_admin_orders_path(date: date.iso8601)
  end

  test "admin opens the page and sees the date form" do
    sign_in @admin
    get_receipts

    assert_response :success
    assert_select "h1", text: "Imprimir remitos por fecha"
    assert_select "form[action=?] input[type=date][name=date][value=?]", receipts_admin_orders_path, DATE.iso8601
  end

  test "only includes orders whose delivery_date is the selected date" do
    on_date = build_order(@alfa)
    day_before = build_order(@beta, date: DATE - 1)
    day_after = build_order(@zeta, date: DATE + 1)

    sign_in @admin
    get_receipts

    assert_select "[data-bulk-receipts-target=receipt]", count: 1
    assert_select "[data-order-number=?]", on_date.number
    assert_select "[data-order-number=?]", day_before.number, count: 0
    assert_select "[data-order-number=?]", day_after.number, count: 0
  end

  test "excludes canceled orders, following the same operational rule as Producción" do
    kept = build_order(@alfa, status: "confirmed")
    canceled = build_order(@beta, status: "canceled")

    sign_in @admin
    get_receipts

    assert_select "[data-bulk-receipts-target=receipt]", count: 1
    assert_select "[data-order-number=?]", kept.number
    assert_select "[data-order-number=?]", canceled.number, count: 0
  end

  test "asks the browser for exactly 2 copies of each receipt and announces the totals" do
    build_order(@alfa)
    build_order(@beta)
    build_order(@zeta)

    sign_in @admin
    get_receipts

    assert_select "[data-controller=bulk-receipts][data-bulk-receipts-copies-value=?]", "2"
    assert_select "[data-bulk-receipts-filename-value=?]", "remitos-2026-10-03.pdf"
    assert_select "#receipts-summary", text: /3 pedidos para el 03\/10\/2026.*6 remitos \(2 copias de cada uno\)/m
    # una sola fuente por pedido: las copias las coloca el armado de hojas, no se duplica el HTML
    assert_select "[data-bulk-receipts-target=receipt]", count: 3
    assert_select "button[data-action=?]", "bulk-receipts#generate", text: "Generar PDF"
  end

  test "renders each receipt with the same partial as the individual receipt, with a unique id" do
    order = build_order(@alfa, items: 3, comment: "Dejar en la puerta de atrás")

    sign_in @admin
    get_receipts

    assert_select "#receipt-#{order.id}.hans-receipt", count: 1
    assert_select "#order-receipt", count: 0 # el id fijo es solo del remito individual
    assert_select ".hans-receipt-number", text: order.number
    assert_select ".hans-receipt-meta .fw-bold", text: "Alfa Cafe"
    assert_select ".hans-receipt-meta .fw-bold", text: "03/10/2026"
    assert_select ".hans-receipt-item", count: 3
    assert_select ".hans-receipt-total-amount", text: format_money_for(order)
    assert_select ".hans-receipt-comment", text: /Dejar en la puerta de atrás/
  end

  test "supports orders with a different number of items (small and large receipts)" do
    small = build_order(@alfa, items: 2)
    large = build_order(@beta, items: 9)

    sign_in @admin
    get_receipts

    assert_select "#receipt-#{small.id} .hans-receipt-item", count: 2
    assert_select "#receipt-#{large.id} .hans-receipt-item", count: 9
  end

  test "keeps long product names and uses the order snapshot, not the current product" do
    order = build_order(@alfa, items: 1)
    long_name = "Alfajor de maicena con dulce de leche y coco rallado"
    order.order_items.first.update_columns(product_name_snapshot: long_name)
    @products.first.update!(name: "Nombre actual distinto")

    sign_in @admin
    get_receipts

    assert_select "#receipt-#{order.id} .hans-receipt-col-product", text: long_name
  end

  test "orders are listed by customer name, then by order id" do
    zeta_order = build_order(@zeta)
    alfa_first = build_order(@alfa)
    alfa_second = build_order(@alfa)
    beta_order = build_order(@beta)

    sign_in @admin
    get_receipts

    numbers = css_select("[data-bulk-receipts-target=receipt]").map { |node| node["data-order-number"] }
    assert_equal [alfa_first, alfa_second, beta_order, zeta_order].map(&:number), numbers
  end

  test "an order without items behaves like the individual receipt (header and stored total, no rows)" do
    order = build_order(@alfa)
    order.order_items.delete_all

    sign_in @admin
    get_receipts

    assert_select "#receipt-#{order.id} .hans-receipt-number", text: order.number
    assert_select "#receipt-#{order.id} .hans-receipt-item", count: 0
    assert_select "#receipt-#{order.id} .hans-receipt-total-amount", text: format_money_for(order.reload)
  end

  test "a date without orders shows a message and no generate button" do
    sign_in @admin
    get_receipts

    assert_response :success
    assert_select "div", text: /No hay pedidos para entregar el 03\/10\/2026/
    assert_select "[data-bulk-receipts-target=receipt]", count: 0
    assert_select "button[data-action=?]", "bulk-receipts#generate", count: 0
  end

  test "without a date param it defaults to today" do
    travel_to Time.zone.local(2026, 10, 3, 9, 0, 0) do
      order = build_order(@alfa)

      sign_in @admin
      get receipts_admin_orders_path

      assert_select "[data-order-number=?]", order.number
    end
  end

  test "an invalid date shows an alert and renders no receipts" do
    build_order(@alfa)

    sign_in @admin
    get receipts_admin_orders_path(date: "no-es-una-fecha")

    assert_response :success
    assert_select ".alert-danger", text: "La fecha no es válida."
    assert_select "[data-bulk-receipts-target=receipt]", count: 0
  end

  test "production can use it (it can already open and download each receipt)" do
    build_order(@alfa)

    sign_in @production
    get_receipts

    assert_response :success
    assert_select "[data-bulk-receipts-target=receipt]", count: 1
  end

  test "a customer cannot access it" do
    customer = Customer.create!(name: "Cliente portal", active: true)
    user = User.create!(email: "receipts-customer@example.com", password: "password123", role: "customer", customer: customer)

    sign_in user
    get_receipts

    assert_redirected_to dashboard_path
  end

  test "a signed-out visitor is sent to sign in" do
    get_receipts

    assert_redirected_to new_user_session_path
  end

  test "the orders index links to it for admin and production" do
    [@admin, @production].each do |user|
      sign_in user
      get admin_orders_path

      assert_select "a[href=?]", receipts_admin_orders_path, text: "Imprimir remitos"
    end
  end

  test "the individual receipt keeps its stable #order-receipt id and PNG button" do
    order = build_order(@alfa)

    sign_in @admin
    get admin_order_path(order)

    assert_select "#order-receipt", count: 1
    assert_select "[data-receipt-export-target-id-value=?]", "order-receipt"
    assert_select "button[data-action=?]", "receipt-export#download", text: "Descargar PNG"
  end

  private

  def format_money_for(order)
    "$#{ActiveSupport::NumberHelper.number_to_delimited(order.total_cents / 100)}"
  end
end
