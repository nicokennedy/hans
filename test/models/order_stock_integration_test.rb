require "test_helper"

# Cubre que Order/OrderItem disparan Stock::DispatchReconciler solos, como
# efecto de guardar, sin que nadie llame al servicio explícitamente — a
# diferencia de test/services/stock/dispatch_reconciler_test.rb, que testea
# el servicio en sí llamándolo directamente.
class OrderStockIntegrationTest < ActiveSupport::TestCase
  def setup
    @category = Category.create!(name: "OrderStockCat#{rand(1_000_000)}", position: 1, active: true)
    @customer = Customer.create!(name: "OrderStockCustomer#{rand(1_000_000)}", active: true)
    @raw = RawMaterial.create!(name: "RM OrderStock #{rand(1_000_000)}", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    @brownie = Preparation.create!(name: "Brownie OrderStock #{rand(1_000_000)}", yield_quantity: 1, yield_unit: "kg")
    @brownie.recipe_components.create!(component: @raw, quantity: 1, unit: "kg")
    @stock_item = StockItem.create!(stockable: @brownie, active: true, quantity: 10, minimum_quantity: 2)

    @mini = Product.create!(name: "Mini OrderStock #{rand(1_000_000)}", category: @category, price_cents: 500, cost_cents: 200, active: true, position: 1)
    ProductRecipe.create!(product: @mini, yield_quantity: 1).recipe_components.create!(component: @brownie, quantity: 1, unit: "kg")

    @other_brownie = Preparation.create!(name: "Other Brownie OrderStock #{rand(1_000_000)}", yield_quantity: 1, yield_unit: "kg")
    @other_brownie.recipe_components.create!(component: @raw, quantity: 1, unit: "kg")
    @other_stock_item = StockItem.create!(stockable: @other_brownie, active: true, quantity: 10, minimum_quantity: 2)
    @other_product = Product.create!(name: "Other OrderStock #{rand(1_000_000)}", category: @category, price_cents: 500, cost_cents: 200, active: true, position: 2)
    ProductRecipe.create!(product: @other_product, yield_quantity: 1).recipe_components.create!(component: @other_brownie, quantity: 1, unit: "kg")

    @sim_day = Date.new(2026, 10, 6)
  end

  def build_order(delivery_date, quantity: 3, product: @mini, status: "received")
    order = Order.new(customer: @customer, delivery_date: delivery_date, created_by_admin: true, payment_method_selected: "cash_on_delivery", status: status)
    order.order_items.build(product: product, quantity: quantity)
    order.save!
    order
  end

  test "saving an order for today, after the cutoff, materializes dispatch automatically without calling the reconciler directly" do
    travel_to Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 13, 30, 0) do
      build_order(@sim_day, quantity: 3)
    end

    assert_equal BigDecimal("7"), @stock_item.reload.quantity
  end

  test "updating an OrderItem's quantity directly, after the cutoff, propagates the delta automatically" do
    order = travel_to(Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 9, 0, 0)) { build_order(@sim_day, quantity: 6) }

    travel_to(Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 13, 0, 0)) { Stock::DispatchReconciler.call(order) }
    travel_to Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 13, 30, 0) do
      order.reload
      order.order_items.first.update!(quantity: 4)
    end

    assert_equal BigDecimal("6"), @stock_item.reload.quantity # 10 - 4
  end

  test "destroying an OrderItem directly, after the cutoff, reverses its share of the dispatch automatically" do
    order = travel_to(Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 9, 0, 0)) do
      o = Order.new(customer: @customer, delivery_date: @sim_day, created_by_admin: true, payment_method_selected: "cash_on_delivery")
      o.order_items.build(product: @mini, quantity: 3)
      o.order_items.build(product: @other_product, quantity: 2)
      o.save!
      o
    end

    travel_to(Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 13, 0, 0)) { Stock::DispatchReconciler.call(order) }
    assert_equal BigDecimal("7"), @stock_item.reload.quantity
    assert_equal BigDecimal("8"), @other_stock_item.reload.quantity

    travel_to Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 14, 0, 0) do
      order.reload.order_items.find_by(product: @other_product).destroy!
    end

    assert_equal BigDecimal("7"), @stock_item.reload.quantity # sin cambios
    assert_equal BigDecimal("10"), @other_stock_item.reload.quantity # se revirtió
  end

  test "swapping an order item's product, after the cutoff, reverses the old product's dispatch and materializes the new one" do
    order = travel_to(Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 9, 0, 0)) { build_order(@sim_day, quantity: 3, product: @mini) }

    travel_to(Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 13, 0, 0)) { Stock::DispatchReconciler.call(order) }
    assert_equal BigDecimal("7"), @stock_item.reload.quantity

    travel_to Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 14, 0, 0) do
      order.reload.order_items.first.update!(product: @other_product, quantity: 3)
    end

    assert_equal BigDecimal("10"), @stock_item.reload.quantity # se revirtió por completo
    assert_equal BigDecimal("7"), @other_stock_item.reload.quantity # se materializó en el nuevo producto
  end

  test "changing delivery_date from today (already materialized) to a future date reverses the dispatch automatically" do
    order = travel_to(Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 9, 0, 0)) { build_order(@sim_day, quantity: 4) }

    travel_to(Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 13, 0, 0)) { Stock::DispatchReconciler.call(order) }
    assert_equal BigDecimal("6"), @stock_item.reload.quantity

    travel_to Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 15, 0, 0) do
      order.reload.update!(delivery_date: @sim_day + 3)
    end

    assert_equal BigDecimal("10"), @stock_item.reload.quantity
  end

  test "canceling an order after materialization reverses the dispatch, via Order's own save callback" do
    order = travel_to(Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 9, 0, 0)) { build_order(@sim_day, quantity: 5) }

    travel_to(Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 13, 0, 0)) { Stock::DispatchReconciler.call(order) }
    assert_equal BigDecimal("5"), @stock_item.reload.quantity

    travel_to Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 16, 0, 0) do
      order.reload.update!(status: "canceled")
    end

    assert_equal BigDecimal("10"), @stock_item.reload.quantity
  end
end
