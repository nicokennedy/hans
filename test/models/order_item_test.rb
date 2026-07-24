require "test_helper"

class OrderItemTest < ActiveSupport::TestCase
  setup do
    @category = Category.create!(name: "Alfajores", position: 1, active: true)
    @product = Product.create!(name: "Alfajor Clásico", category: @category, price_cents: 300, cost_cents: 100, active: true, position: 1)
    @other_product = Product.create!(name: "Torta Brownie", category: @category, price_cents: 900, cost_cents: 500, active: true, position: 2)
    @customer = Customer.create!(name: "Cliente Test", active: true)
    @order = Order.create!(customer: @customer, delivery_date: Date.tomorrow)
  end

  test "calculates subtotal from quantity and snapshot price on create" do
    item = @order.order_items.create!(product: @product, quantity: 3)

    assert_equal 300, item.unit_price_cents_snapshot
    assert_equal 100, item.unit_cost_cents_snapshot
    assert_equal 900, item.line_revenue_cents
    assert_equal 300, item.line_cost_cents
  end

  test "recalculates subtotal when quantity changes" do
    item = @order.order_items.create!(product: @product, quantity: 2)

    item.update!(quantity: 5)

    assert_equal 1500, item.line_revenue_cents
  end

  test "requires quantity to be greater than zero" do
    item = @order.order_items.build(product: @product, quantity: 0)

    assert_not item.valid?
    assert item.errors[:quantity].present?
  end

  test "unit_price_amount= updates the price snapshot in pesos and recalculates the subtotal" do
    item = @order.order_items.create!(product: @product, quantity: 2)

    item.update!(unit_price_amount: "500")

    assert_equal 50_000, item.unit_price_cents_snapshot
    assert_equal 100_000, item.line_revenue_cents
    assert_equal 300, @product.reload.price_cents
  end

  test "rejects a negative unit price" do
    item = @order.order_items.build(product: @product, quantity: 1, unit_price_amount: "-5")

    assert_not item.valid?
    assert item.errors[:unit_price_cents_snapshot].present?
  end

  test "changing Product#price_cents after the order exists does not alter the order item's historical snapshot or total" do
    item = @order.order_items.create!(product: @product, quantity: 3)
    original_unit_price = item.unit_price_cents_snapshot
    original_line_revenue = item.line_revenue_cents
    original_total = @order.reload.total_cents

    @product.update!(price_cents: 999_999)

    item.reload
    assert_equal original_unit_price, item.unit_price_cents_snapshot
    assert_equal 300, item.unit_price_cents_snapshot
    assert_equal original_line_revenue, item.line_revenue_cents
    assert_equal original_total, @order.reload.total_cents
    assert_not_equal @product.price_cents, item.unit_price_cents_snapshot
  end

  test "assign_product updates name, category and cost snapshots but leaves the price untouched" do
    item = @order.order_items.create!(product: @product, quantity: 2)
    original_price = item.unit_price_cents_snapshot

    item.assign_product(@other_product)
    item.save!

    assert_equal @other_product.id, item.product_id
    assert_equal @other_product.name, item.product_name_snapshot
    assert_equal @other_product.category.name, item.category_name_snapshot
    assert_equal @other_product.cost_cents, item.unit_cost_cents_snapshot
    assert_equal original_price, item.unit_price_cents_snapshot
  end
end
