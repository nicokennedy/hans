require "test_helper"

class Stock::InsufficientStockCheckerTest < ActiveSupport::TestCase
  AVAILABLE_DAY = Date.new(2026, 10, 7) # miércoles, no bloqueado
  BEFORE_CUTOFF = Time.zone.local(2026, 10, 6, 12, 0, 0)

  def setup
    @customer = Customer.create!(name: "InsufficientStockCustomer#{rand(1_000_000)}", active: true)
    @category = Category.create!(name: "InsufficientStockCat#{rand(1_000_000)}", position: 1, active: true)
  end

  def build_strict_product(stock_quantity:, minimum: 0, name: "Strict #{rand(1_000_000)}")
    product = Product.create!(name: name, category: @category, price_cents: 500, cost_cents: 200, active: true, position: 1, sell_without_stock: false)
    StockItem.create!(stock_tracking_started_on: Date.new(2026, 1, 1), stockable: product, active: true, quantity: stock_quantity, minimum_quantity: minimum)
    product
  end

  def build_lenient_product(stock_quantity: nil, minimum: 0, name: "Lenient #{rand(1_000_000)}")
    product = Product.create!(name: name, category: @category, price_cents: 500, cost_cents: 200, active: true, position: 2, sell_without_stock: true)
    StockItem.create!(stock_tracking_started_on: Date.new(2026, 1, 1), stockable: product, active: true, quantity: stock_quantity, minimum_quantity: minimum) if stock_quantity
    product
  end

  def new_order(delivery_date: AVAILABLE_DAY)
    Order.new(customer: @customer, delivery_date: delivery_date, payment_method_selected: "cash_on_delivery")
  end

  test "an order for a default (sell_without_stock: true) product is never blocked, regardless of stock" do
    product = build_lenient_product(stock_quantity: 0)

    order = travel_to(BEFORE_CUTOFF) do
      order = new_order
      order.order_items.build(product: product, quantity: 50)
      order.save
      order
    end

    assert order.persisted?
  end

  test "an order for a strict (sell_without_stock: false) product without an active StockItem is not blocked" do
    product = Product.create!(name: "StrictNoStock#{rand(1_000_000)}", category: @category, price_cents: 500, cost_cents: 200, active: true, position: 1, sell_without_stock: false)

    order = travel_to(BEFORE_CUTOFF) do
      order = new_order
      order.order_items.build(product: product, quantity: 5)
      order.save
      order
    end

    assert order.persisted?
  end

  test "blocks an order for a strict product when available stock is insufficient" do
    product = build_strict_product(stock_quantity: 3)

    order = travel_to(BEFORE_CUTOFF) do
      order = new_order
      order.order_items.build(product: product, quantity: 5)
      order.save
      order
    end

    assert_not order.persisted?
    assert order.errors[:base].any? { |m| m.include?("No hay stock suficiente") }
  end

  test "allows an order for a strict product when available stock is sufficient" do
    product = build_strict_product(stock_quantity: 10)

    order = travel_to(BEFORE_CUTOFF) do
      order = new_order
      order.order_items.build(product: product, quantity: 5)
      order.save
      order
    end

    assert order.persisted?
  end

  test "a lenient product sharing the same stock pool as a strict product still counts toward the strict product's availability check" do
    harina = RawMaterial.create!(name: "Harina ChkPool", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    pool = Preparation.create!(name: "Pool ChkPool", yield_quantity: 1, yield_unit: "kg")
    pool.recipe_components.create!(component: harina, quantity: 1, unit: "kg")
    StockItem.create!(stock_tracking_started_on: Date.new(2026, 1, 1), stockable: pool, active: true, quantity: 5, minimum_quantity: 0)

    strict = Product.create!(name: "StrictPool#{rand(1_000_000)}", category: @category, price_cents: 500, cost_cents: 200, active: true, position: 1, sell_without_stock: false)
    ProductRecipe.create!(product: strict, yield_quantity: 1).recipe_components.create!(component: pool, quantity: 1, unit: "kg")

    lenient = Product.create!(name: "LenientPool#{rand(1_000_000)}", category: @category, price_cents: 500, cost_cents: 200, active: true, position: 2, sell_without_stock: true)
    ProductRecipe.create!(product: lenient, yield_quantity: 1).recipe_components.create!(component: pool, quantity: 1, unit: "kg")

    # 5kg disponibles. 3kg para el estricto (alcanzaría solo) + 3kg para el
    # laxo (que igual se vende sin importar el stock) agotan el pool común.
    order = travel_to(BEFORE_CUTOFF) do
      order = new_order
      order.order_items.build(product: strict, quantity: 3)
      order.order_items.build(product: lenient, quantity: 3)
      order.save
      order
    end

    assert_not order.persisted?
    assert order.errors[:base].any? { |m| m.include?("No hay stock suficiente") }
  end

  test "created_by_admin bypasses the stock validation entirely" do
    product = build_strict_product(stock_quantity: 0)

    order = travel_to(BEFORE_CUTOFF) do
      order = Order.new(customer: @customer, delivery_date: AVAILABLE_DAY, payment_method_selected: "cash_on_delivery", created_by_admin: true)
      order.order_items.build(product: product, quantity: 100)
      order.save
      order
    end

    assert order.persisted?
  end

  test "reports one violation per insufficient strict product, not just the first" do
    product_a = build_strict_product(stock_quantity: 1, name: "StrictA#{rand(1_000_000)}")
    product_b = build_strict_product(stock_quantity: 1, name: "StrictB#{rand(1_000_000)}")

    order = travel_to(BEFORE_CUTOFF) do
      order = new_order
      order.order_items.build(product: product_a, quantity: 5)
      order.order_items.build(product: product_b, quantity: 5)
      order.save
      order
    end

    assert_not order.persisted?
    assert_equal 2, order.errors[:base].count { |m| m.include?("No hay stock suficiente") }
  end

  test "two sequential customer orders competing for the same limited stock: the first succeeds, the second is blocked" do
    product = build_strict_product(stock_quantity: 5)

    first_order = travel_to(BEFORE_CUTOFF) do
      order = new_order
      order.order_items.build(product: product, quantity: 5)
      order.save
      order
    end
    assert first_order.persisted?

    second_order = travel_to(BEFORE_CUTOFF) do
      order = new_order
      order.order_items.build(product: product, quantity: 1)
      order.save
      order
    end
    assert_not second_order.persisted?
  end
end
