require "test_helper"

class OrdersControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @category = Category.create!(name: "Alfajores", position: 1, active: true)
    @product = Product.create!(name: "Alfajor Clásico", category: @category, price_cents: 500, cost_cents: 200, active: true, position: 1)
    @customer = Customer.create!(name: "Cliente Test", active: true)
    @user = User.create!(email: "customer-orders@example.com", password: "password123", role: "customer", customer: @customer)

    @order = @customer.orders.new(delivery_date: Date.tomorrow)
    @order.order_items.build(product: @product, quantity: 2)
    @order.save! # total_cents = 1000
  end

  test "should get new" do
    sign_in @user
    get new_order_path
    assert_redirected_to cart_path # empty cart redirects, but route/action resolve correctly
  end

  test "show displays total, paid amount and balance, with the payment status tag instead of the operational status" do
    @order.payments.create!(amount_cents: 400, paid_at: Time.current, payment_method: "cash_on_delivery")
    sign_in @user

    get order_path(@order)

    assert_response :success
    assert_select ".badge", text: "Pago parcial"
    assert_no_match "Received", response.body
    assert_select "div", text: "Recibido"
    assert_match "$4", response.body
    assert_match "$6", response.body
  end

  test "index shows the account statement totals, excluding canceled orders" do
    canceled_order = @customer.orders.new(delivery_date: Date.tomorrow, status: "canceled")
    canceled_order.order_items.build(product: @product, quantity: 5) # would add 2500 if counted
    canceled_order.save!

    @order.payments.create!(amount_cents: 400, paid_at: Time.current, payment_method: "cash_on_delivery")

    sign_in @user
    get orders_path

    assert_response :success
    assert_select ".product-card", text: /Total facturado.*\$10/m
    assert_select ".product-card", text: /Total pagado.*\$4/m
    assert_select ".product-card", text: /Saldo pendiente.*\$6/m
  end

  test "index shows paid amount, balance and translated payment status per order" do
    @order.payments.create!(amount_cents: 1_000, paid_at: Time.current, payment_method: "bank_transfer")

    sign_in @user
    get orders_path

    assert_response :success
    assert_match "Pagado: $10", response.body
    assert_match "Saldo: $0", response.body
    assert_select ".badge", text: "Pagado"
  end

  test "index renders the Pagado badge in green (bg-success)" do
    @order.payments.create!(amount_cents: 1_000, paid_at: Time.current, payment_method: "bank_transfer")
    assert_equal "paid", @order.reload.payment_status

    sign_in @user
    get orders_path

    assert_response :success
    assert_select ".badge.bg-success", text: "Pagado"
  end

  test "index renders the Pago parcial badge in orange/amber (bg-warning)" do
    @order.payments.create!(amount_cents: 400, paid_at: Time.current, payment_method: "cash_on_delivery")
    assert_equal "partial", @order.reload.payment_status

    sign_in @user
    get orders_path

    assert_response :success
    assert_select ".badge.bg-warning", text: "Pago parcial"
  end

  test "index renders the Pendiente badge in yellow (bg-warning-subtle), never bg-secondary or a red/danger class" do
    assert_equal "pending", @order.payment_status

    sign_in @user
    get orders_path

    assert_response :success
    assert_select ".badge.bg-warning-subtle", text: "Pendiente"
    assert_select ".badge.bg-secondary", text: "Pendiente", count: 0
    assert_select ".badge.bg-danger", text: "Pendiente", count: 0
  end

  test "show (order detail) uses the same colored badge classes as the index, unified via the shared helper" do
    sign_in @user
    get order_path(@order)

    assert_response :success
    assert_select ".badge.bg-warning-subtle", text: "Pendiente"
  end

  test "payment status labels stay in Spanish exactly as before (Pendiente/Pago parcial/Pagado), unchanged by the badge color change" do
    sign_in @user

    get orders_path
    assert_select ".badge", text: "Pendiente"

    @order.payments.create!(amount_cents: 400, paid_at: Time.current, payment_method: "cash_on_delivery")
    get orders_path
    assert_select ".badge", text: "Pago parcial"

    @order.payments.create!(amount_cents: 600, paid_at: Time.current, payment_method: "bank_transfer")
    get orders_path
    assert_select ".badge", text: "Pagado"
  end

  test "the payment_status calculation logic itself is untouched: it still derives from registered payments, not from the badge helper" do
    assert_equal "pending", @order.payment_status
    @order.payments.create!(amount_cents: 400, paid_at: Time.current, payment_method: "cash_on_delivery")
    assert_equal "partial", @order.reload.payment_status
    @order.payments.create!(amount_cents: 600, paid_at: Time.current, payment_method: "bank_transfer")
    assert_equal "paid", @order.reload.payment_status
  end

  test "a customer cannot register a payment through the admin route" do
    sign_in @user

    assert_no_difference "Payment.count" do
      post admin_order_payments_path(@order), params: {
        payment: { amount: "4", paid_at: Date.current, payment_method: "cash_on_delivery" }
      }
    end
    assert_redirected_to dashboard_path
  end

  test "a customer cannot delete a payment through the admin route" do
    payment = @order.payments.create!(amount_cents: 400, paid_at: Time.current, payment_method: "cash_on_delivery")
    sign_in @user

    assert_no_difference "Payment.count" do
      delete admin_order_payment_path(@order, payment)
    end
    assert_redirected_to dashboard_path
  end

  test "a customer cannot view another customer's order" do
    other_customer = Customer.create!(name: "Otro Cliente", active: true)
    other_order = other_customer.orders.new(delivery_date: Date.tomorrow)
    other_order.order_items.build(product: @product, quantity: 1)
    other_order.save!

    sign_in @user
    get order_path(other_order)

    assert_response :not_found
  end

  test "the receipt block shows order number, customer, order date, delivery date, quantity, unit price, subtotal and total" do
    sign_in @user
    get order_path(@order)

    assert_response :success
    assert_match @order.number, response.body
    assert_match @customer.name, response.body
    assert_match @order.created_at.strftime("%d/%m/%Y"), response.body
    assert_match @order.delivery_date.strftime("%d/%m/%Y"), response.body
    assert_match "2", response.body # quantity
    assert_match "Alfajor Clásico", response.body
    assert_select ".hans-receipt-col-unit", text: /\$5/ # unit price ($500/100 quantized as pesos... see setup: price_cents 500)
    assert_select ".hans-receipt-total-amount", text: "$10"
  end

  test "the customer order page does not show the admin/production Descargar PNG button (not expanding client permissions)" do
    sign_in @user
    get order_path(@order)

    assert_response :success
    assert_no_match "Descargar PNG", response.body
  end

  test "the customer detail page never exposes cost_cents or internal cost figures" do
    sign_in @user
    get order_path(@order)

    assert_response :success
    assert_no_match(/cost_cents/, response.body)
    assert_no_match(/costo interno/i, response.body)
  end

  test "the customer order page shows no administrative section (no register-payment form, no delete-payment button)" do
    @order.payments.create!(amount_cents: 400, paid_at: Time.current, payment_method: "cash_on_delivery")
    sign_in @user

    get order_path(@order)

    assert_response :success
    assert_no_match "Registrar pago", response.body
    assert_no_match "Información administrativa", response.body
    assert_select "button", text: "Eliminar", count: 0
    assert_select "a", text: "Editar pedido", count: 0
  end

  test "no raw 'Cash on delivery' English text ever leaks to the customer, and it shows the Spanish label" do
    @order.update!(payment_method_selected: "cash_on_delivery")
    sign_in @user

    get order_path(@order)

    assert_response :success
    assert_no_match(/cash on delivery/i, response.body)
    assert_match "Efectivo contraentrega", response.body
  end

  test "checkout offers Efectivo contraentrega as a payment method option" do
    sign_in @user
    post add_cart_path, params: { product_id: @product.id }

    get new_order_path

    assert_response :success
    assert_select "select#order_payment_method_selected option", text: "Efectivo contraentrega"
  end

  test "a customer cannot create an order for Tuesday" do
    assert_blocked_for_customer(next_weekday(2))
  end

  test "a customer cannot create an order for Thursday" do
    assert_blocked_for_customer(next_weekday(4))
  end

  test "a customer cannot create an order for Sunday" do
    assert_blocked_for_customer(next_weekday(0))
  end

  test "a customer can create an order for an allowed day" do
    allowed_date = next_weekday(1) # lunes

    sign_in @user
    post add_cart_path, params: { product_id: @product.id }

    assert_difference "Order.count", 1 do
      post orders_path, params: { order: { delivery_date: allowed_date, payment_method_selected: "cash_on_delivery" } }
    end

    order = @customer.orders.order(:id).last
    assert_redirected_to order_path(order)
    assert_equal allowed_date, order.delivery_date
  end

  private

  def assert_blocked_for_customer(blocked_date)
    assert DeliveryDateValidator.reason(blocked_date).present?, "test setup expects #{blocked_date} to be blocked"

    sign_in @user
    post add_cart_path, params: { product_id: @product.id }

    assert_no_difference "Order.count" do
      post orders_path, params: { order: { delivery_date: blocked_date, payment_method_selected: "cash_on_delivery" } }
    end

    assert_response :unprocessable_entity
    assert_match "No realizamos entregas los martes, jueves ni domingos", response.body
  end

  def next_weekday(wday)
    date = Date.tomorrow
    date += 1 until date.wday == wday
    date
  end
end
