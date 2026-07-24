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

  test "no raw 'Cash on delivery' English text ever leaks to the customer" do
    @order.update!(payment_method_selected: "cash_on_delivery")
    sign_in @user

    get order_path(@order)

    assert_response :success
    assert_no_match(/cash on delivery/i, response.body)
    assert_match "Cuenta corriente", response.body
  end
end
