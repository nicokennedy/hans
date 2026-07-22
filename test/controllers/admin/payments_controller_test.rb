require "test_helper"

class Admin::PaymentsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = User.create!(email: "payments-admin@example.com", password: "password123", role: "admin")
    @category = Category.create!(name: "Alfajores", position: 1, active: true)
    @product = Product.create!(name: "Alfajor Clásico", category: @category, price_cents: 500, cost_cents: 200, active: true, position: 1)
    @customer = Customer.create!(name: "Cliente Test", active: true)
    @order = Order.new(customer: @customer, delivery_date: Date.tomorrow)
    @order.order_items.build(product: @product, quantity: 2)
    @order.save! # total_cents = 1000
  end

  test "an admin registers a payment and the order recalculates" do
    sign_in @admin

    assert_difference "Payment.count", 1 do
      post admin_order_payments_path(@order), params: {
        payment: { amount: "4", paid_at: Date.current, payment_method: "cash_on_delivery", note: "Seña" }
      }
    end

    assert_redirected_to admin_order_path(@order)
    @order.reload
    assert_equal 400, @order.amount_paid_cents
    assert_equal "partial", @order.payment_status
  end

  test "an admin registers multiple partial payments that reach paid" do
    sign_in @admin

    post admin_order_payments_path(@order), params: {
      payment: { amount: "4", paid_at: Date.current, payment_method: "cash_on_delivery" }
    }
    post admin_order_payments_path(@order), params: {
      payment: { amount: "6", paid_at: Date.current, payment_method: "bank_transfer" }
    }

    @order.reload
    assert_equal 1_000, @order.amount_paid_cents
    assert_equal "paid", @order.payment_status
  end

  test "rejects an overpayment via HTTP without persisting anything" do
    sign_in @admin

    assert_no_difference "Payment.count" do
      post admin_order_payments_path(@order), params: {
        payment: { amount: "11", paid_at: Date.current, payment_method: "cash_on_delivery" }
      }
    end

    assert_redirected_to admin_order_path(@order)
    @order.reload
    assert_equal 0, @order.amount_paid_cents
    assert_equal "pending", @order.payment_status
  end

  test "an admin deletes a payment and the order recalculates" do
    sign_in @admin
    payment = @order.payments.create!(amount_cents: 400, paid_at: Time.current, payment_method: "cash_on_delivery")
    @order.reload
    assert_equal "partial", @order.payment_status

    assert_difference "Payment.count", -1 do
      delete admin_order_payment_path(@order, payment)
    end

    assert_redirected_to admin_order_path(@order)
    @order.reload
    assert_equal 0, @order.amount_paid_cents
    assert_equal "pending", @order.payment_status
  end

  test "a non-admin customer cannot register or delete a payment" do
    regular_customer = Customer.create!(name: "Otro Cliente", active: true)
    regular_user = User.create!(email: "payments-regular@example.com", password: "password123", role: "customer", customer: regular_customer)
    sign_in regular_user

    assert_no_difference "Payment.count" do
      post admin_order_payments_path(@order), params: {
        payment: { amount: "4", paid_at: Date.current, payment_method: "cash_on_delivery" }
      }
    end
    assert_redirected_to dashboard_path

    payment = @order.payments.create!(amount_cents: 400, paid_at: Time.current, payment_method: "cash_on_delivery")
    assert_no_difference "Payment.count" do
      delete admin_order_payment_path(@order, payment)
    end
    assert_redirected_to dashboard_path
  end

  test "an anonymous user cannot register or delete a payment" do
    assert_no_difference "Payment.count" do
      post admin_order_payments_path(@order), params: {
        payment: { amount: "4", paid_at: Date.current, payment_method: "cash_on_delivery" }
      }
    end
    assert_response :redirect

    payment = @order.payments.create!(amount_cents: 400, paid_at: Time.current, payment_method: "cash_on_delivery")
    assert_no_difference "Payment.count" do
      delete admin_order_payment_path(@order, payment)
    end
    assert_response :redirect
  end

  test "the order_id cannot be overridden by a param in the request body" do
    other_customer = Customer.create!(name: "Otro Cliente Body", active: true)
    other_order = Order.create!(customer: other_customer, delivery_date: Date.tomorrow)
    other_order.order_items.create!(product: @product, quantity: 1)

    sign_in @admin

    post admin_order_payments_path(@order), params: {
      payment: { amount: "4", paid_at: Date.current, payment_method: "cash_on_delivery", order_id: other_order.id }
    }

    payment = Payment.order(:id).last
    assert_equal @order.id, payment.order_id
  end
end
