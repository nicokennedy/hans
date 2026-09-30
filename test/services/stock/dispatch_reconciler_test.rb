require "test_helper"

class Stock::DispatchReconcilerTest < ActiveSupport::TestCase
  def setup
    @category = Category.create!(name: "ReconcilerCat#{rand(1_000_000)}", position: 1, active: true)
    @customer = Customer.create!(name: "ReconcilerCustomer#{rand(1_000_000)}", active: true)
    @raw = RawMaterial.create!(name: "RM Reconciler #{rand(1_000_000)}", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    @brownie = Preparation.create!(name: "Brownie Reconciler #{rand(1_000_000)}", yield_quantity: 1, yield_unit: "kg")
    @brownie.recipe_components.create!(component: @raw, quantity: 1, unit: "kg")
    @stock_item = StockItem.create!(stockable: @brownie, active: true, quantity: 10, minimum_quantity: 2)

    @mini = Product.create!(name: "Mini Reconciler #{rand(1_000_000)}", category: @category, price_cents: 500, cost_cents: 200, active: true, position: 1)
    @mini_recipe = ProductRecipe.create!(product: @mini, yield_quantity: 1)
    @mini_recipe.recipe_components.create!(component: @brownie, quantity: 1, unit: "kg") # 1kg/unidad, simple

    @sim_day = Date.new(2026, 10, 6) # martes, arbitrario — created_by_admin bypasea la regla de día habitual
  end

  def build_order(delivery_date, quantity: 1, status: "received")
    order = Order.new(customer: @customer, delivery_date: delivery_date, created_by_admin: true, payment_method_selected: "cash_on_delivery", status: status)
    order.order_items.build(product: @mini, quantity: quantity)
    order.save!
    order
  end

  test "hoy 12:59 -> NO materializa salidas de hoy" do
    order = travel_to(Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 9, 0, 0)) { build_order(@sim_day) }

    travel_to Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 12, 59, 0) do
      Stock::DispatchReconciler.call(order)
    end

    assert_equal 0, StockMovement.dispatch.where(order: order).count
    assert_equal BigDecimal("10"), @stock_item.reload.quantity
  end

  test "hoy 13:00 -> SÍ materializa" do
    order = travel_to(Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 9, 0, 0)) { build_order(@sim_day) }

    travel_to Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 13, 0, 0) do
      Stock::DispatchReconciler.call(order)
    end

    assert_equal BigDecimal("9"), @stock_item.reload.quantity
    assert_equal 1, StockMovement.dispatch.where(order: order).count
  end

  test "hoy 13:01 -> sigue idempotente, no duplica" do
    order = travel_to(Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 9, 0, 0)) { build_order(@sim_day) }

    travel_to Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 13, 0, 0) do
      Stock::DispatchReconciler.call(order)
    end

    travel_to Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 13, 1, 0) do
      Stock::DispatchReconciler.call(order)
      Stock::DispatchReconciler.call(order)
    end

    assert_equal BigDecimal("9"), @stock_item.reload.quantity
    assert_equal 1, StockMovement.dispatch.where(order: order).count
  end

  test "pedido de ayer -> materializa independientemente de la hora" do
    yesterday = @sim_day - 1
    order = travel_to(Time.zone.local(yesterday.year, yesterday.month, yesterday.day, 9, 0, 0)) { build_order(yesterday) }

    travel_to Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 8, 0, 0) do
      Stock::DispatchReconciler.call(order)
    end

    assert_equal BigDecimal("9"), @stock_item.reload.quantity
  end

  test "pedido futuro -> no materializa" do
    future_day = @sim_day + 5
    order = travel_to(Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 9, 0, 0)) { build_order(future_day) }

    travel_to Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 15, 0, 0) do
      Stock::DispatchReconciler.call(order)
    end

    assert_equal BigDecimal("10"), @stock_item.reload.quantity
  end

  test "canceled -> no consume" do
    order = travel_to(Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 9, 0, 0)) { build_order(@sim_day, status: "canceled") }

    travel_to Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 15, 0, 0) do
      Stock::DispatchReconciler.call(order)
    end

    assert_equal BigDecimal("10"), @stock_item.reload.quantity
    assert_equal 0, StockMovement.dispatch.where(order: order).count
  end

  test "modificación después de 13 -> delta correcto" do
    order = travel_to(Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 9, 0, 0)) { build_order(@sim_day, quantity: 6) }

    travel_to(Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 13, 0, 0)) { Stock::DispatchReconciler.call(order) }
    assert_equal BigDecimal("4"), @stock_item.reload.quantity # 10 - 6

    travel_to Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 15, 0, 0) do
      order.order_items.first.update!(quantity: 5)
      Stock::DispatchReconciler.call(order)
    end

    assert_equal BigDecimal("5"), @stock_item.reload.quantity # devuelve 1
  end

  test "cancelación después de 13 -> reversión correcta" do
    order = travel_to(Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 9, 0, 0)) { build_order(@sim_day, quantity: 6) }

    travel_to(Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 13, 0, 0)) { Stock::DispatchReconciler.call(order) }
    assert_equal BigDecimal("4"), @stock_item.reload.quantity

    travel_to Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 15, 0, 0) do
      order.update!(status: "canceled")
    end

    assert_equal BigDecimal("10"), @stock_item.reload.quantity
  end

  test "reconcile_due! is safe to run repeatedly without duplicating movements" do
    order = travel_to(Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 9, 0, 0)) { build_order(@sim_day, quantity: 3) }

    travel_to Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 14, 0, 0) do
      result1 = Stock::DispatchReconciler.reconcile_due!
      result2 = Stock::DispatchReconciler.reconcile_due!
      assert_equal 1, result1.reconciled
      assert result2.errors.empty?
    end

    assert_equal BigDecimal("7"), @stock_item.reload.quantity
  end

  test "a single broken order does not block reconciling the rest" do
    good_order = travel_to(Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 9, 0, 0)) { build_order(@sim_day, quantity: 1) }
    broken_order = travel_to(Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 9, 0, 0)) { build_order(@sim_day, quantity: 1) }

    Stock::DispatchReconciler.stub(:call, ->(order, now: Time.current) { raise "boom" if order == broken_order; Stock::DispatchReconciler.new(order, now: now).call }) do
      travel_to Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 14, 0, 0) do
        result = Stock::DispatchReconciler.reconcile_due!
        assert_equal 1, result.reconciled
        assert_equal 1, result.errors.size
      end
    end
  end
end
