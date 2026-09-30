require "test_helper"

class Stock::DemandTest < ActiveSupport::TestCase
  def build_product(name: "Product Demand #{rand(1_000_000)}")
    category = Category.create!(name: "DemandCat#{rand(1_000_000)}", position: 1, active: true)
    Product.create!(name: name, category: category, price_cents: 500, cost_cents: 200, active: true, position: 1)
  end

  def build_order_item(product, quantity)
    OrderItem.new(product: product, quantity: quantity)
  end

  test "aggregates consumption across two different products that share the same Preparation stock pool" do
    harina = RawMaterial.create!(name: "Harina Demand", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    brownie = Preparation.create!(name: "Brownie Demand", yield_quantity: 1, yield_unit: "kg")
    brownie.recipe_components.create!(component: harina, quantity: 1, unit: "kg")
    brownie_stock = StockItem.create!(stockable: brownie, active: true, quantity: 10, minimum_quantity: 2)

    mini = build_product(name: "Mini Demand")
    ProductRecipe.create!(product: mini, yield_quantity: 100).recipe_components.create!(component: brownie, quantity: 2.8, unit: "kg")

    cuadrado = build_product(name: "Cuadrado Demand")
    ProductRecipe.create!(product: cuadrado, yield_quantity: 70).recipe_components.create!(component: brownie, quantity: 1, unit: "kg")

    demand = Stock::Demand.for_order_items([
      build_order_item(mini, 10),
      build_order_item(cuadrado, 14),
    ])

    expected = (BigDecimal("0.028") * 10) + ((BigDecimal(1) / BigDecimal(70)) * 14)
    assert_in_delta expected, demand[brownie_stock], BigDecimal("0.0000001")
  end

  test "multiple order_items for the same product accumulate instead of overwriting" do
    category = Category.create!(name: "DemandCat2#{rand(1_000_000)}", position: 1, active: true)
    product = Product.create!(name: "Product Demand Self", category: category, price_cents: 500, cost_cents: 200, active: true, position: 1)
    stock_item = StockItem.create!(stockable: product, active: true, quantity: 10, minimum_quantity: 1)

    demand = Stock::Demand.for_order_items([
      build_order_item(product, 3),
      build_order_item(product, 2),
    ])

    assert_equal BigDecimal("5"), demand[stock_item]
  end

  test "products with no stock-relevant components are simply absent from the result" do
    raw = RawMaterial.create!(name: "RM Demand Direct", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    product = build_product
    recipe = ProductRecipe.create!(product: product, yield_quantity: 1)
    recipe.recipe_components.create!(component: raw, quantity: 1, unit: "kg")

    demand = Stock::Demand.for_order_items([build_order_item(product, 5)])

    assert_equal BigDecimal(0), demand[StockItem.new]
    assert demand.empty?
  end

  test "an empty list of order_items returns an empty demand" do
    assert_equal({}, Stock::Demand.for_order_items([]))
  end

  test "a shared instance correctly accumulates repeated products across separate calls" do
    harina = RawMaterial.create!(name: "Harina Demand Memo", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    brownie = Preparation.create!(name: "Brownie Demand Memo", yield_quantity: 1, yield_unit: "kg")
    brownie.recipe_components.create!(component: harina, quantity: 1, unit: "kg")
    brownie_stock = StockItem.create!(stockable: brownie, active: true, quantity: 10, minimum_quantity: 2)

    mini = build_product(name: "Mini Demand Memo")
    ProductRecipe.create!(product: mini, yield_quantity: 10).recipe_components.create!(component: brownie, quantity: 1, unit: "kg")

    order_items = [build_order_item(mini, 3), build_order_item(mini, 4)]
    result = Stock::Demand.for_order_items(order_items)

    assert_equal BigDecimal("0.7"), result[brownie_stock]
  end
end
