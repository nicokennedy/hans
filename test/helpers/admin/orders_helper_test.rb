require "test_helper"

class Admin::OrdersHelperTest < ActionView::TestCase
  setup do
    @category = Category.create!(name: "Alfajores", position: 1, active: true)
    @active_product = Product.create!(name: "Producto Activo", category: @category, price_cents: 100, cost_cents: 50, active: true, position: 1)
    @inactive_product = Product.create!(name: "Producto Inactivo", category: @category, price_cents: 200, cost_cents: 80, active: false, position: 2)
    @customer = Customer.create!(name: "Cliente Test", active: true)
    @order = Order.create!(customer: @customer, delivery_date: Date.tomorrow)
  end

  test "includes the item's own product even when it is inactive" do
    item = @order.order_items.create!(product: @inactive_product, quantity: 1)

    html = order_item_product_options(item, Product.active.ordered)

    assert_includes html, @inactive_product.name
    assert_includes html, @active_product.name
  end

  test "does not duplicate the item's product when it is already active" do
    item = @order.order_items.create!(product: @active_product, quantity: 1)

    html = order_item_product_options(item, Product.active.ordered)

    assert_equal 1, html.scan(@active_product.name).size
  end

  test "does not add inactive products other than the item's own" do
    another_inactive = Product.create!(name: "Otro Inactivo", category: @category, price_cents: 300, cost_cents: 90, active: false, position: 3)
    item = @order.order_items.create!(product: @active_product, quantity: 1)

    html = order_item_product_options(item, Product.active.ordered)

    assert_not_includes html, another_inactive.name
  end
end
