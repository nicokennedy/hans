require "test_helper"

# "Volver" respeta la sección de origen: un pago iniciado desde Pedidos vuelve a Pedidos con sus
# filtros; uno iniciado desde Clientes (ficha o cuenta corriente) vuelve a Clientes con la búsqueda.
class Admin::NavigationContextTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  DAY = Date.new(2026, 10, 6)

  setup do
    @admin = User.create!(email: "nav-admin@example.com", password: "password123", role: "admin")
    category = Category.create!(name: "Nav Cat", position: 1, active: true)
    @product = Product.create!(name: "Alfajor Nav", category: category, price_cents: 10_000, cost_cents: 100, active: true, position: 1)
    @ala = Customer.create!(name: "Ala Moana", active: true)
    @monke = Customer.create!(name: "Casa Monke", active: true)
    @ala_order = build_order(@ala)
    @monke_order = build_order(@monke)
    sign_in @admin
  end

  def build_order(customer, quantity: 2)
    order = Order.new(customer: customer, delivery_date: DAY, created_by_admin: true, payment_method_selected: "cash_on_delivery")
    order.order_items.build(product: @product, quantity: quantity)
    order.save!
    order
  end

  def back_href
    css_select("#back-to-orders").first["href"]
  end

  def pay_order(order, amount, context = {})
    post admin_order_payments_path(order), params: context.merge(payment: { amount: amount, paid_at: DAY, payment_method: "cash_on_delivery" })
  end

  # --- Caso A: desde Pedidos -------------------------------------------------------------

  test "A: order filtered by Ala Moana -> payment -> Volver returns to Pedidos with every filter" do
    filters = { customer_id: @ala.id.to_s, delivery_date: DAY.iso8601, payment_status_filter: "pending" }
    get admin_orders_path(filters)
    assert_select "a[href=?]", admin_order_path(@ala_order, filters)

    get admin_order_path(@ala_order, filters)
    assert_equal admin_orders_path(filters), back_href

    pay_order(@ala_order, "50", filters)
    assert_redirected_to admin_order_path(@ala_order, filters)
    follow_redirect!
    assert_equal admin_orders_path(filters), back_href
    assert_equal 5_000, @ala_order.reload.amount_paid_cents
  end

  test "A: an invalid order payment keeps the filters, and the corrected retry too" do
    filters = { customer_id: @ala.id.to_s, payment_status_filter: "pending" }

    pay_order(@ala_order, "999", filters) # supera el saldo
    assert_redirected_to admin_order_path(@ala_order, filters)
    assert_equal 0, @ala_order.reload.amount_paid_cents

    pay_order(@ala_order, "200", filters)
    assert_redirected_to admin_order_path(@ala_order, filters)
    assert_equal 20_000, @ala_order.reload.amount_paid_cents
  end

  # --- Caso B: desde Clientes ------------------------------------------------------------

  test "B: Clientes searched Monke -> ficha -> cuenta corriente -> pago -> Volver keeps the search" do
    get admin_customers_path(q: "Monke")
    assert_select "a[href=?]", admin_customer_account_path(@monke, q: "Monke"), text: "Cuenta corriente"
    assert_select "a[href=?]", admin_customer_path(@monke, q: "Monke"), text: "Ver"

    get admin_customer_path(@monke, q: "Monke")
    account = admin_customer_account_path(@monke, q: "Monke", via: "customer")
    assert_select "a[href=?]", account, text: "Cuenta corriente"

    get account
    assert_select "#back-from-account[href=?]", admin_customer_path(@monke, q: "Monke"), text: "← Cliente"
    assert_select "#register-payment[href=?]", new_admin_customer_customer_payment_path(@monke, q: "Monke", via: "customer")

    get new_admin_customer_customer_payment_path(@monke, q: "Monke", via: "customer")
    assert_select "a[href=?]", account, text: "Cancelar"
    assert_select "form input[type=hidden][name=q][value=Monke]"
    assert_select "form input[type=hidden][name=via][value=customer]"

    assert_difference -> { CustomerPayment.count }, 1 do
      post admin_customer_customer_payments_path(@monke), params: {
        q: "Monke", via: "customer", amount: "200", paid_on: DAY.iso8601, payment_method: "bank_transfer",
        request_token: SecureRandom.uuid, allocations: { @monke_order.id.to_s => "200" }
      }
    end
    assert_redirected_to account
    follow_redirect!
    assert_select "#back-from-account[href=?]", admin_customer_path(@monke, q: "Monke")

    get admin_customer_path(@monke, q: "Monke")
    assert_select "a[href=?]", admin_customers_path(q: "Monke"), text: "← Clientes"
    assert_equal 20_000, @monke_order.reload.amount_paid_cents
  end

  test "B: from the account, Ver pedido -> payment -> Volver goes back to the account, never to Pedidos" do
    context = { q: "Monke", via: "customer", filter: "pending", from: "2026-10-01", to: "2026-10-31" }
    get admin_customer_account_path(@monke, context)
    order_link = admin_order_path(@monke_order, context.merge(back_to: "account"))
    assert_select "a[href=?]", order_link, text: "Ver pedido"

    get order_link
    assert_equal admin_customer_account_path(@monke, context), back_href
    assert_select "#back-to-orders", text: "← Cuenta corriente"

    pay_order(@monke_order, "50", context.merge(back_to: "account"))
    assert_redirected_to order_link
    follow_redirect!
    assert_equal admin_customer_account_path(@monke, context), back_href
  end

  test "B: from the customer ficha, Ver pedido -> Volver returns to the ficha with the search" do
    get admin_customer_path(@monke, q: "Monke")
    order_link = admin_order_path(@monke_order, q: "Monke", back_to: "customer")
    assert_select "a[href=?]", order_link, text: "Ver pedido"

    get order_link
    assert_equal admin_customer_path(@monke, q: "Monke"), back_href
  end

  test "B: account filters and the search survive the account's own filter form and links" do
    get admin_customer_account_path(@monke, q: "Monke", filter: "pending")
    assert_select "form[action=?] input[type=hidden][name=q][value=Monke]", admin_customer_account_path(@monke)
    assert_select "a[href=?]", admin_customer_account_path(@monke, q: "Monke"), text: "Todos"
    assert_select "a[href=?]", admin_customer_account_path(@monke, q: "Monke"), text: "Limpiar"
  end

  test "B: a customer payment with a validation error keeps the context, and the retry returns with it" do
    context = { q: "Monke", via: "customer" }
    post admin_customer_customer_payments_path(@monke), params: context.merge(amount: "0", paid_on: DAY.iso8601, payment_method: "bank_transfer", request_token: SecureRandom.uuid)

    assert_response :unprocessable_entity
    assert_select "form input[type=hidden][name=q][value=Monke]"
    assert_select "a[href=?]", admin_customer_account_path(@monke, context), text: "Cancelar"
    assert_equal 0, CustomerPayment.count

    post admin_customer_customer_payments_path(@monke), params: context.merge(
      amount: "100", paid_on: DAY.iso8601, payment_method: "bank_transfer", request_token: SecureRandom.uuid, allocations: { @monke_order.id.to_s => "100" }
    )
    assert_redirected_to admin_customer_account_path(@monke, context)
  end

  test "B: voiding a payment from the account returns to the account with its context" do
    payment = CustomerAccounts::RegisterPayment.call(customer: @monke, user: @admin, amount_cents: 10_000, paid_on: DAY,
                                                     payment_method: "bank_transfer", allocations: { @monke_order.id => 10_000 }).customer_payment

    post void_admin_customer_customer_payment_path(@monke, payment), params: { q: "Monke", reason: "Error de carga" }
    assert_redirected_to admin_customer_account_path(@monke, q: "Monke")
    assert payment.reload.voided?
  end

  # --- Caso C y accesos directos -------------------------------------------------------

  test "C: without filters each section returns to itself" do
    get admin_order_path(@ala_order)
    assert_equal admin_orders_path, back_href

    get admin_customer_account_path(@ala)
    assert_select "#back-from-account[href=?]", admin_customers_path, text: "← Clientes"

    get admin_customer_path(@ala)
    assert_select "a[href=?]", admin_customer_account_path(@ala, via: "customer"), text: "Cuenta corriente"
    assert_select "a[href=?]", admin_order_path(@ala_order, back_to: "customer"), text: "Ver pedido"
  end

  test "invalid or external destinations are ignored and never end up in a link" do
    get admin_order_path(@ala_order, back_to: "https://evil.example.com", via: "//evil.example.com", from: "javascript:alert(1)", filter: "x")
    assert_equal admin_orders_path, back_href
    assert_no_unsafe_destinations

    get admin_customer_account_path(@ala, via: "https://evil.example.com", from: "2026-13-45")
    assert_select "#back-from-account[href=?]", admin_customers_path
    assert_no_unsafe_destinations
  end

  # Ningún link, formulario ni campo oculto arrastra el valor manipulado.
  def assert_no_unsafe_destinations
    values = css_select("a[href], form[action]").map { |node| node["href"] || node["action"] } + css_select("input[type=hidden]").map { |node| node["value"].to_s }
    assert values.none? { |value| value.include?("evil.example.com") || value.include?("javascript") }, values.grep(/evil|javascript/).inspect
  end

  test "back_to always targets the order's own customer, whatever customer_id says" do
    get admin_order_path(@ala_order, back_to: "account", customer_id: @monke.id.to_s)
    assert_equal admin_customer_account_path(@ala), back_href
  end
end
