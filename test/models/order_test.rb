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
end
