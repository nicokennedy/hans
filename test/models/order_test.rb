require "test_helper"

class OrderTest < ActiveSupport::TestCase
  setup do
    @category = Category.create!(name: "Alfajores", position: 1, active: true)
    @product = Product.create!(name: "Alfajor Clásico", category: @category, price_cents: 300, cost_cents: 100, active: true, position: 1)
    @other_product = Product.create!(name: "Torta Brownie", category: @category, price_cents: 900, cost_cents: 500, active: true, position: 2)
    @customer = Customer.create!(name: "Cliente Test", active: true)
  end

  test "recalculates total from all order items on create" do
    order = Order.new(customer: @customer, delivery_date: Date.tomorrow)
    order.order_items.build(product: @product, quantity: 2)
    order.order_items.build(product: @other_product, quantity: 1)

    order.save!

    assert_equal 1500, order.total_cents
  end

  test "recalculates total after an item is destroyed directly, without counting stale in-memory items" do
    order = Order.create!(customer: @customer, delivery_date: Date.tomorrow)
    order.order_items.create!(product: @product, quantity: 2)
    removable_item = order.order_items.create!(product: @other_product, quantity: 1)

    # Mirrors how the admin controller removes a line: fetched from the
    # already-loaded association and destroyed directly, not via
    # order.order_items.destroy(item).
    order.order_items.find(removable_item.id).destroy!
    order.update!(status: "confirmed")

    assert_equal 600, order.total_cents
    assert_equal 1, order.order_items.count
  end

  test "prevents an update from leaving the order without any items" do
    order = Order.create!(customer: @customer, delivery_date: Date.tomorrow)
    item = order.order_items.create!(product: @product, quantity: 1)

    item.destroy!

    assert_raises(ActiveRecord::RecordInvalid) { order.update!(status: "confirmed") }
  end

  test "recalculate_payment_state! derives pending, partial and paid from registered payments" do
    order = Order.new(customer: @customer, delivery_date: Date.tomorrow)
    order.order_items.build(product: @product, quantity: 2)
    order.save! # total_cents = 600

    assert_equal "pending", order.payment_status

    order.payments.create!(amount_cents: 200, paid_at: Time.current, payment_method: "cash_on_delivery")
    assert_equal "partial", order.reload.payment_status

    order.payments.create!(amount_cents: 400, paid_at: Time.current, payment_method: "bank_transfer")
    assert_equal "paid", order.reload.payment_status
  end

  test "editing order items after payments exist keeps payment_status consistent with the new total" do
    order = Order.new(customer: @customer, delivery_date: Date.tomorrow)
    item = order.order_items.build(product: @product, quantity: 2)
    order.save! # total_cents = 600

    order.payments.create!(amount_cents: 600, paid_at: Time.current, payment_method: "cash_on_delivery")
    order.reload
    assert_equal "paid", order.payment_status

    item.update!(quantity: 4) # total_cents now 1200, only 600 paid
    order.update!(status: "confirmed")

    assert_equal "partial", order.reload.payment_status
    assert_equal 600, order.balance_due_cents
  end

  test "not_canceled excludes canceled orders" do
    kept = Order.create!(customer: @customer, delivery_date: Date.tomorrow, status: "confirmed")
    kept.order_items.create!(product: @product, quantity: 1)

    canceled = Order.create!(customer: @customer, delivery_date: Date.tomorrow, status: "canceled")
    canceled.order_items.create!(product: @product, quantity: 1)

    result = Order.where(id: [kept.id, canceled.id]).not_canceled
    assert_includes result, kept
    assert_not_includes result, canceled
  end

  test "cash_on_delivery and cash_later both show the Cuenta corriente label, without changing the stored value" do
    cash_on_delivery_order = Order.create!(customer: @customer, delivery_date: Date.tomorrow, payment_method_selected: "cash_on_delivery")
    cash_later_order = Order.create!(customer: @customer, delivery_date: Date.tomorrow, payment_method_selected: "cash_later")

    assert_equal "Cuenta corriente", cash_on_delivery_order.payment_method_selected_label
    assert_equal "Cuenta corriente", cash_later_order.payment_method_selected_label
    assert_equal "cash_on_delivery", cash_on_delivery_order.payment_method_selected
    assert_equal "cash_later", cash_later_order.payment_method_selected
  end

  test "bank_transfer shows Transferencia bancaria, and a blank payment method returns nil" do
    order = Order.create!(customer: @customer, delivery_date: Date.tomorrow, payment_method_selected: "bank_transfer")
    blank_order = Order.create!(customer: @customer, delivery_date: Date.tomorrow)

    assert_equal "Transferencia bancaria", order.payment_method_selected_label
    assert_nil blank_order.payment_method_selected_label
  end

  test "payment_method_options_for_select never offers two indistinguishable options with the same label" do
    options = Order.payment_method_options_for_select
    labels = options.map(&:first)

    assert_equal labels.uniq, labels
    assert_includes labels, "Cuenta corriente"
    assert_includes labels, "Transferencia bancaria"
  end
end
