require "test_helper"

class OrderTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

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

  test "cash_on_delivery shows Efectivo contraentrega and cash_later shows Cuenta corriente, each with its own distinct label" do
    cash_on_delivery_order = Order.create!(customer: @customer, delivery_date: Date.tomorrow, payment_method_selected: "cash_on_delivery")
    cash_later_order = Order.create!(customer: @customer, delivery_date: Date.tomorrow, payment_method_selected: "cash_later")

    assert_equal "Efectivo contraentrega", cash_on_delivery_order.payment_method_selected_label
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

  test "payment_method_options_for_select offers all three payment methods, including Efectivo contraentrega" do
    options = Order.payment_method_options_for_select

    assert_equal 3, options.size
    assert_includes options, [ "Efectivo contraentrega", "cash_on_delivery" ]
    assert_includes options, [ "Cuenta corriente", "cash_later" ]
    assert_includes options, [ "Transferencia bancaria", "bank_transfer" ]
  end

  test "creating an order broadcasts exactly one order_created event and enqueues exactly one push job" do
    assert_broadcast_on("orders_channel", type: "order_created") do
      assert_enqueued_with(job: PushNotificationJob) do
        order = Order.new(customer: @customer, delivery_date: Date.tomorrow)
        order.order_items.build(product: @product, quantity: 1)
        order.save!
        @created_order_for_cleanup = order
      end
    end
  ensure
    @created_order_for_cleanup&.order_items&.destroy_all
    @created_order_for_cleanup&.destroy
  end

  test "the push job is enqueued with the order's id, not a serialized record" do
    order = Order.new(customer: @customer, delivery_date: Date.tomorrow)
    order.order_items.build(product: @product, quantity: 1)

    assert_enqueued_with(job: PushNotificationJob) { order.save! }

    enqueued = enqueued_jobs.find { |j| j["job_class"] == "PushNotificationJob" || j[:job] == PushNotificationJob }
    args = enqueued[:args] || enqueued["arguments"]
    assert_equal order.id, args.first
  ensure
    order.order_items.destroy_all
    order.destroy
  end

  test "editing an existing order (delivery date) does not broadcast a new order_created event" do
    order = Order.new(customer: @customer, delivery_date: Date.tomorrow)
    order.order_items.build(product: @product, quantity: 1)
    order.save!

    assert_no_broadcasts("orders_channel") do
      order.update!(delivery_date: Date.tomorrow + 1.day)
    end
  ensure
    order.order_items.destroy_all
    order.destroy
  end

  test "changing status does not broadcast a new order_created event" do
    order = Order.new(customer: @customer, delivery_date: Date.tomorrow)
    order.order_items.build(product: @product, quantity: 1)
    order.save!

    assert_no_broadcasts("orders_channel") do
      order.update!(status: "confirmed")
    end
  ensure
    order.order_items.destroy_all
    order.destroy
  end

  test "registering a payment does not broadcast a new order_created event" do
    order = Order.new(customer: @customer, delivery_date: Date.tomorrow)
    order.order_items.build(product: @product, quantity: 1)
    order.save!

    assert_no_broadcasts("orders_channel") do
      order.payments.create!(amount_cents: 100, paid_at: Time.current, payment_method: "cash_on_delivery")
    end
  ensure
    order.payments.destroy_all
    order.order_items.destroy_all
    order.destroy
  end

  test "a failed order creation (invalid record) never broadcasts" do
    assert_no_broadcasts("orders_channel") do
      order = Order.new(customer: @customer, delivery_date: nil) # invalid: delivery_date required
      order.order_items.build(product: @product, quantity: 1)
      assert_not order.save
    end
  end
end
