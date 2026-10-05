require "test_helper"

class Stock::ProductConsumptionTest < ActiveSupport::TestCase
  def build_product(name: "Product PC #{rand(1_000_000)}")
    category = Category.create!(name: "PCCat#{rand(1_000_000)}", position: 1, active: true)
    Product.create!(name: name, category: category, price_cents: 500, cost_cents: 200, active: true, position: 1)
  end

  test "a Product with its own active StockItem resolves to itself with a 1:1 multiplier" do
    scon = build_product(name: "Scon Queso PC")
    stock_item = StockItem.create!(stock_tracking_started_on: Date.new(2026, 1, 1), stockable: scon, active: true, quantity: 18, minimum_quantity: 20)

    map = Stock::ProductConsumption.call(scon)

    assert_equal BigDecimal(1), map[stock_item]
  end

  test "Mini Brownie and Cuadrado Brownie resolve to the same Preparation stock_item, each with its own per-unit multiplier" do
    harina = RawMaterial.create!(name: "Harina PC", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    brownie = Preparation.create!(name: "Brownie PC", yield_quantity: 1, yield_unit: "kg")
    brownie.recipe_components.create!(component: harina, quantity: 1, unit: "kg")
    brownie_stock = StockItem.create!(stock_tracking_started_on: Date.new(2026, 1, 1), stockable: brownie, active: true, quantity: 3, minimum_quantity: 2)

    mini = build_product(name: "Mini Brownie PC")
    mini_recipe = ProductRecipe.create!(product: mini, yield_quantity: 100)
    mini_recipe.recipe_components.create!(component: brownie, quantity: 2.8, unit: "kg")

    cuadrado = build_product(name: "Cuadrado Brownie PC")
    cuadrado_recipe = ProductRecipe.create!(product: cuadrado, yield_quantity: 70)
    cuadrado_recipe.recipe_components.create!(component: brownie, quantity: 1, unit: "kg")

    mini_map = Stock::ProductConsumption.call(mini)
    cuadrado_map = Stock::ProductConsumption.call(cuadrado)

    assert_equal BigDecimal("0.028"), mini_map[brownie_stock]
    assert_in_delta (BigDecimal(1) / BigDecimal(70)), cuadrado_map[brownie_stock], BigDecimal("0.0000001")
  end

  test "RawMaterial components are never treated as stock — only Preparation/Product matter" do
    raw = RawMaterial.create!(name: "RM PC Direct", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    product = build_product
    recipe = ProductRecipe.create!(product: product, yield_quantity: 1)
    recipe.recipe_components.create!(component: raw, quantity: 1, unit: "kg")

    map = Stock::ProductConsumption.call(product)

    assert_equal({}, map)
  end

  test "a non-stock-controlled Preparation is transparent — consumption passes through to its own components" do
    harina = RawMaterial.create!(name: "Harina PC Nested", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")

    base = Preparation.create!(name: "Base PC Nested", yield_quantity: 1, yield_unit: "kg")
    base.recipe_components.create!(component: harina, quantity: 1, unit: "kg")
    base_stock = StockItem.create!(stock_tracking_started_on: Date.new(2026, 1, 1), stockable: base, active: true, quantity: 5, minimum_quantity: 1)

    # Masa Sable NO controla stock -> el consumo de Base debe "pasar a través" de ella
    masa = Preparation.create!(name: "Masa Sable PC Nested", yield_quantity: 2, yield_unit: "kg")
    masa.recipe_components.create!(component: base, quantity: 1, unit: "kg") # 0.5kg base / kg masa

    product = build_product
    recipe = ProductRecipe.create!(product: product, yield_quantity: 10)
    recipe.recipe_components.create!(component: masa, quantity: 4, unit: "kg") # 0.4kg masa / unidad

    map = Stock::ProductConsumption.call(product)

    # 0.4kg masa/unidad * 0.5kg base/kg masa = 0.2kg base/unidad
    assert_in_delta BigDecimal("0.2"), map[base_stock], BigDecimal("0.0000001")
  end

  test "a nested Preparation that IS stock-controlled stops the recursion there — its own ingredients are irrelevant" do
    harina = RawMaterial.create!(name: "Harina PC Stop", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")

    inner = Preparation.create!(name: "Inner PC Stop", yield_quantity: 1, yield_unit: "kg")
    inner.recipe_components.create!(component: harina, quantity: 1, unit: "kg")
    inner_stock = StockItem.create!(stock_tracking_started_on: Date.new(2026, 1, 1), stockable: inner, active: true, quantity: 5, minimum_quantity: 1)

    outer = Preparation.create!(name: "Outer PC Stop", yield_quantity: 1, yield_unit: "kg")
    outer.recipe_components.create!(component: inner, quantity: 1, unit: "kg")

    product = build_product
    recipe = ProductRecipe.create!(product: product, yield_quantity: 1)
    recipe.recipe_components.create!(component: outer, quantity: 1, unit: "kg")

    map = Stock::ProductConsumption.call(product)

    assert_equal BigDecimal(1), map[inner_stock]
    assert_equal 1, map.size
  end

  test "a Preparation without an active StockItem (inactive) is treated as non-controlled and passed through" do
    harina = RawMaterial.create!(name: "Harina PC Inactive", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")

    base = Preparation.create!(name: "Base PC Inactive", yield_quantity: 1, yield_unit: "kg")
    base.recipe_components.create!(component: harina, quantity: 1, unit: "kg")
    StockItem.create!(stock_tracking_started_on: Date.new(2026, 1, 1), stockable: base, active: false, quantity: 5, minimum_quantity: 1)

    product = build_product
    recipe = ProductRecipe.create!(product: product, yield_quantity: 1)
    recipe.recipe_components.create!(component: base, quantity: 1, unit: "kg")

    map = Stock::ProductConsumption.call(product)

    assert_equal({}, map)
  end

  test "a Product without a ProductRecipe and without its own StockItem resolves to an empty map" do
    product = build_product

    assert_equal({}, Stock::ProductConsumption.call(product))
  end

  test "unit conversion (g vs kg) is respected when computing per-unit consumption" do
    harina = RawMaterial.create!(name: "Harina PC Units", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    brownie = Preparation.create!(name: "Brownie PC Units", yield_quantity: 1, yield_unit: "kg")
    brownie.recipe_components.create!(component: harina, quantity: 1, unit: "kg")
    brownie_stock = StockItem.create!(stock_tracking_started_on: Date.new(2026, 1, 1), stockable: brownie, active: true, quantity: 3, minimum_quantity: 2)

    product = build_product
    recipe = ProductRecipe.create!(product: product, yield_quantity: 10)
    recipe.recipe_components.create!(component: brownie, quantity: 500, unit: "g") # 0.5kg total / 10 = 0.05kg/un

    map = Stock::ProductConsumption.call(product)

    assert_equal BigDecimal("0.05"), map[brownie_stock]
  end
end
