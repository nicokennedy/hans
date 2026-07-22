require "test_helper"

class PaymentTest < ActiveSupport::TestCase
  setup do
    @category = Category.create!(name: "Alfajores", position: 1, active: true)
    @product = Product.create!(name: "Alfajor Clásico", category: @category, price_cents: 500, cost_cents: 200, active: true, position: 1)
    @customer = Customer.create!(name: "Cliente Test", active: true)
    @order = Order.new(customer: @customer, delivery_date: Date.tomorrow)
    @order.order_items.build(product: @product, quantity: 2)
    @order.save! # total_cents = 1000
  end

  test "requires a positive amount" do
    payment = Payment.new(order: @order, amount_cents: 0, paid_at: Time.current, payment_method: "cash_on_delivery")
    assert_not payment.valid?
    assert payment.errors[:amount_cents].present?
  end

  test "requires paid_at" do
    payment = Payment.new(order: @order, amount_cents: 500, paid_at: nil, payment_method: "cash_on_delivery")
    assert_not payment.valid?
    assert payment.errors[:paid_at].present?
  end

  test "requires a valid payment method" do
    payment = Payment.new(order: @order, amount_cents: 500, paid_at: Time.current, payment_method: nil)
    assert_not payment.valid?
    assert payment.errors[:payment_method].present?
  end

  test "requires an order" do
    payment = Payment.new(order: nil, amount_cents: 500, paid_at: Time.current, payment_method: "cash_on_delivery")
    assert_not payment.valid?
  end

  test "amount= converts pesos to cents" do
    payment = Payment.new(order: @order, paid_at: Time.current, payment_method: "cash_on_delivery")
    payment.amount = "500"
    assert_equal 50_000, payment.amount_cents
  end

  test "rejects a single payment that exceeds the order balance" do
    payment = Payment.new(order: @order, amount_cents: 1_001, paid_at: Time.current, payment_method: "cash_on_delivery")
    assert_not payment.valid?
    assert payment.errors[:amount_cents].present?
  end

  test "rejects cumulative payments that exceed the order balance" do
    @order.payments.create!(amount_cents: 700, paid_at: Time.current, payment_method: "cash_on_delivery")

    second_payment = Payment.new(order: @order, amount_cents: 400, paid_at: Time.current, payment_method: "bank_transfer")
    assert_not second_payment.valid?
  end

  test "allows a payment that exactly matches the remaining balance" do
    payment = Payment.new(order: @order, amount_cents: 1_000, paid_at: Time.current, payment_method: "cash_on_delivery")
    assert payment.valid?
  end

  test "recalculates the order to partial after a first partial payment" do
    @order.payments.create!(amount_cents: 400, paid_at: Time.current, payment_method: "cash_on_delivery")

    @order.reload
    assert_equal 400, @order.amount_paid_cents
    assert_equal "partial", @order.payment_status
    assert_equal 600, @order.balance_due_cents
  end

  test "recalculates the order to paid once multiple partial payments reach the total" do
    @order.payments.create!(amount_cents: 400, paid_at: Time.current, payment_method: "cash_on_delivery")
    @order.payments.create!(amount_cents: 600, paid_at: Time.current, payment_method: "bank_transfer")

    @order.reload
    assert_equal 1_000, @order.amount_paid_cents
    assert_equal "paid", @order.payment_status
    assert_equal 0, @order.balance_due_cents
  end

  test "recalculates the order back down after a payment is destroyed" do
    first = @order.payments.create!(amount_cents: 400, paid_at: Time.current, payment_method: "cash_on_delivery")
    @order.payments.create!(amount_cents: 600, paid_at: Time.current, payment_method: "bank_transfer")
    @order.reload
    assert_equal "paid", @order.payment_status

    first.destroy!

    @order.reload
    assert_equal 600, @order.amount_paid_cents
    assert_equal "partial", @order.payment_status
  end
end
