require "test_helper"

class Stock::AvailabilityTest < ActiveSupport::TestCase
  def setup
    @category = Category.create!(name: "AvailabilityCat#{rand(1_000_000)}", position: 1, active: true)
    @customer = Customer.create!(name: "AvailabilityCustomer#{rand(1_000_000)}", active: true)
    @raw = RawMaterial.create!(name: "RM Availability #{rand(1_000_000)}", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    @brownie = Preparation.create!(name: "Brownie Availability #{rand(1_000_000)}", yield_quantity: 1, yield_unit: "kg")
    @brownie.recipe_components.create!(component: @raw, quantity: 1, unit: "kg")

    @mini = Product.create!(name: "Mini Availability #{rand(1_000_000)}", category: @category, price_cents: 500, cost_cents: 200, active: true, position: 1)
    ProductRecipe.create!(product: @mini, yield_quantity: 1).recipe_components.create!(component: @brownie, quantity: 1, unit: "kg")

    @sim_day = Date.new(2026, 10, 6)
  end

  def build_stock_item(quantity:, minimum:)
    StockItem.create!(stock_tracking_started_on: Date.new(2026, 1, 1), stockable: @brownie, active: true, quantity: quantity, minimum_quantity: minimum)
  end

  def build_order(delivery_date, quantity: 1, status: "received")
    order = Order.new(customer: @customer, delivery_date: delivery_date, created_by_admin: true, payment_method_selected: "cash_on_delivery", status: status)
    order.order_items.build(product: @mini, quantity: quantity)
    order.save!
    order
  end

  test "available subtracts both future committed and today's pending dispatch before the cutoff" do
    stock_item = build_stock_item(quantity: 10, minimum: 2)
    travel_to(Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 9, 0, 0)) { build_order(@sim_day + 5, quantity: 2) }
    travel_to(Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 9, 0, 0)) { build_order(@sim_day, quantity: 3) }

    snapshot = travel_to(Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 12, 0, 0)) do
      Stock::Availability.for_item(stock_item, now: Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 12, 0, 0))
    end

    assert_equal BigDecimal("10"), snapshot.physical_quantity
    assert_equal BigDecimal("2"), snapshot.future_committed
    assert_equal BigDecimal("3"), snapshot.today_dispatch
    assert_not snapshot.today_dispatch_materialized
    assert_equal BigDecimal("5"), snapshot.available_quantity # 10 - 2 - 3
  end

  test "after the cutoff, today's dispatch is materialized into physical and not subtracted again" do
    stock_item = build_stock_item(quantity: 10, minimum: 2)
    travel_to(Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 9, 0, 0)) { build_order(@sim_day, quantity: 3) }

    snapshot = Stock::Availability.for_item(stock_item, now: Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 13, 0, 0))

    assert_equal BigDecimal("7"), snapshot.physical_quantity # ya materializado
    assert_equal BigDecimal("3"), snapshot.today_dispatch # sigue visible
    assert snapshot.today_dispatch_materialized
    assert_equal BigDecimal("7"), snapshot.available_quantity # NO se resta de nuevo
  end

  test "status is red when available is strictly below minimum" do
    stock_item = build_stock_item(quantity: 5, minimum: 10)

    snapshot = Stock::Availability.for_item(stock_item, now: Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 8, 0, 0))

    assert_equal :red, snapshot.status
    assert_equal BigDecimal("5"), snapshot.production_needed # 10 - 5
  end

  test "status is red at the exact boundary where available equals minimum minus a hair (still below)" do
    stock_item = build_stock_item(quantity: BigDecimal("9.999"), minimum: 10)

    snapshot = Stock::Availability.for_item(stock_item, now: Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 8, 0, 0))

    assert_equal :red, snapshot.status
  end

  test "status is orange when available equals minimum exactly" do
    stock_item = build_stock_item(quantity: 10, minimum: 10)

    snapshot = Stock::Availability.for_item(stock_item, now: Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 8, 0, 0))

    assert_equal :orange, snapshot.status
    assert_equal BigDecimal(0), snapshot.production_needed
  end

  test "status is orange when available equals minimum times 1.2 exactly (inclusive upper boundary)" do
    stock_item = build_stock_item(quantity: 12, minimum: 10) # 12 == 10 * 1.2

    snapshot = Stock::Availability.for_item(stock_item, now: Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 8, 0, 0))

    assert_equal :orange, snapshot.status
  end

  test "status is green when available exceeds minimum times 1.2" do
    stock_item = build_stock_item(quantity: BigDecimal("12.01"), minimum: 10)

    snapshot = Stock::Availability.for_item(stock_item, now: Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 8, 0, 0))

    assert_equal :green, snapshot.status
    assert_equal BigDecimal(0), snapshot.production_needed
  end

  test "production_needed is zero once available reaches the minimum, never negative" do
    stock_item = build_stock_item(quantity: 100, minimum: 10)

    snapshot = Stock::Availability.for_item(stock_item, now: Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 8, 0, 0))

    assert_equal BigDecimal(0), snapshot.production_needed
  end

  test "canceled orders never count toward future_committed or today_dispatch" do
    stock_item = build_stock_item(quantity: 10, minimum: 2)
    travel_to(Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 9, 0, 0)) { build_order(@sim_day, quantity: 4, status: "canceled") }

    snapshot = Stock::Availability.for_item(stock_item, now: Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 10, 0, 0))

    assert_equal BigDecimal(0), snapshot.today_dispatch
    assert_equal BigDecimal("10"), snapshot.available_quantity
  end

  test "dashboard aggregates demand from two products sharing the same Preparation stock pool" do
    stock_item = build_stock_item(quantity: 10, minimum: 2)
    cuadrado = Product.create!(name: "Cuadrado Availability", category: @category, price_cents: 500, cost_cents: 200, active: true, position: 2)
    ProductRecipe.create!(product: cuadrado, yield_quantity: 1).recipe_components.create!(component: @brownie, quantity: BigDecimal("0.5"), unit: "kg")

    travel_to(Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 9, 0, 0)) do
      order = Order.new(customer: @customer, delivery_date: @sim_day + 5, created_by_admin: true, payment_method_selected: "cash_on_delivery", status: "received")
      order.order_items.build(product: @mini, quantity: 2) # 2kg
      order.order_items.build(product: cuadrado, quantity: 2) # 1kg
      order.save!
    end

    snapshots = Stock::Availability.dashboard(now: Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 10, 0, 0))
    snapshot = snapshots.find { |s| s.stock_item == stock_item }

    assert_equal BigDecimal("3"), snapshot.future_committed # 2kg + 1kg
  end

  test "dashboard sorts red before orange before green, and within a status by descending production_needed" do
    red_low = build_stock_item(quantity: 1, minimum: 10) # falta 9
    red_high = build_stock_item(quantity: 1, minimum: 20) # falta 19
    orange = build_stock_item(quantity: 10, minimum: 10)
    green = build_stock_item(quantity: 100, minimum: 10)

    snapshots = Stock::Availability.dashboard(now: Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 8, 0, 0))
    ordered_items = snapshots.map(&:stock_item)

    assert_equal [ red_high, red_low ], ordered_items.select { |i| [ red_high, red_low ].include?(i) }
    assert_operator ordered_items.index(red_low), :<, ordered_items.index(orange)
    assert_operator ordered_items.index(orange), :<, ordered_items.index(green)
  end

  test "dashboard only includes active StockItems" do
    active_item = build_stock_item(quantity: 5, minimum: 2)
    inactive_item = StockItem.create!(stock_tracking_started_on: Date.new(2026, 1, 1), stockable: Preparation.create!(name: "Inactive Availability #{rand(1_000_000)}", yield_quantity: 1, yield_unit: "kg"), active: false, quantity: 5, minimum_quantity: 2)

    snapshots = Stock::Availability.dashboard(now: Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 8, 0, 0))
    items = snapshots.map(&:stock_item)

    assert_includes items, active_item
    assert_not_includes items, inactive_item
  end

  test "for_items runs the pending reconciliation as a safety net before computing the snapshot" do
    stock_item = build_stock_item(quantity: 10, minimum: 2)
    order = travel_to(Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 9, 0, 0)) { build_order(@sim_day, quantity: 3) }

    # Nadie llamó explícitamente al reconciler — Availability debe hacerlo como red de seguridad.
    snapshot = Stock::Availability.for_item(stock_item, now: Time.zone.local(@sim_day.year, @sim_day.month, @sim_day.day, 14, 0, 0))

    assert_equal BigDecimal("7"), stock_item.reload.quantity
    assert_equal BigDecimal("7"), snapshot.physical_quantity
  end
end
