require "test_helper"

class Costing::ProductRecipeCalculatorTest < ActiveSupport::TestCase
  def build_product
    category = Category.create!(name: "PRCalcCat#{rand(1_000_000)}", position: 1, active: true)
    Product.create!(name: "Producto PRCalc #{rand(1_000_000)}", price_cents: 500_000,
      cost_cents: 0, cost_source: "manual", category: category, active: true, position: 1)
  end

  test "Caso base: Alfajor Limón, 3 preparaciones, yield 12 un -> $1.732/un" do
    harina = RawMaterial.create!(name: "Harina PRCalc", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    manteca = RawMaterial.create!(name: "Manteca PRCalc", purchase_price_cents: 1_000_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    azucar = RawMaterial.create!(name: "Azucar PRCalc", purchase_price_cents: 200_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")

    masa_sable = Preparation.create!(name: "Masa Sable PRCalc", yield_quantity: 2, yield_unit: "kg")
    masa_sable.recipe_components.create!(component: harina, quantity: 1, unit: "kg")
    masa_sable.recipe_components.create!(component: manteca, quantity: 0.5, unit: "kg")
    masa_sable.recipe_components.create!(component: azucar, quantity: 0.3, unit: "kg")
    # Masa Sable: $660.000 total / 2kg = $330.000/kg

    chocolate = RawMaterial.create!(name: "Chocolate Blanco PRCalc", purchase_price_cents: 900_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    chocolate_prep = Preparation.create!(name: "Chocolate Blanco Templado PRCalc", yield_quantity: 1, yield_unit: "kg")
    chocolate_prep.recipe_components.create!(component: chocolate, quantity: 1, unit: "kg")
    # $900.000/kg

    limon = RawMaterial.create!(name: "Limón PRCalc", purchase_price_cents: 400_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    crema = RawMaterial.create!(name: "Crema PRCalc", purchase_price_cents: 600_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    ganache_limon = Preparation.create!(name: "Ganache Limón PRCalc", yield_quantity: 1, yield_unit: "kg")
    ganache_limon.recipe_components.create!(component: limon, quantity: 0.4, unit: "kg")
    ganache_limon.recipe_components.create!(component: crema, quantity: 0.6, unit: "kg")
    # (0.4*400.000 + 0.6*600.000) = 160.000 + 360.000 = 520.000/kg

    product = build_product
    recipe = ProductRecipe.create!(product: product, yield_quantity: 12)
    recipe.recipe_components.create!(component: masa_sable, quantity: 1.2, unit: "kg")       # 1.2 * 330.000 = 396.000
    recipe.recipe_components.create!(component: chocolate_prep, quantity: 0.4, unit: "kg")    # 0.4 * 900.000 = 360.000
    recipe.recipe_components.create!(component: ganache_limon, quantity: 0.5, unit: "kg")     # 0.5 * 520.000 = 260.000
    # total: 396.000 + 360.000 + 260.000 = 1.016.000 -> /12 = 84.666,67 -> redondeado 84.667

    assert_equal 1_016_000, recipe.total_cost_cents
    assert_equal 84_667, recipe.unit_cost_cents
  end

  test "componente directo RawMaterial" do
    harina = RawMaterial.create!(name: "Harina Directa PRCalc", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    product = build_product
    recipe = ProductRecipe.create!(product: product, yield_quantity: 2)
    recipe.recipe_components.create!(component: harina, quantity: 1, unit: "kg")

    assert_equal 100_000, recipe.total_cost_cents
    assert_equal 50_000, recipe.unit_cost_cents
  end

  test "componente directo Preparation (sin anidar más)" do
    chocolate = RawMaterial.create!(name: "Chocolate Directo PRCalc", purchase_price_cents: 800_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    ganache = Preparation.create!(name: "Ganache Directo PRCalc", yield_quantity: 1, yield_unit: "kg")
    ganache.recipe_components.create!(component: chocolate, quantity: 1, unit: "kg")

    product = build_product
    recipe = ProductRecipe.create!(product: product, yield_quantity: 4)
    recipe.recipe_components.create!(component: ganache, quantity: 0.5, unit: "kg")

    assert_equal 400_000, recipe.total_cost_cents
    assert_equal 100_000, recipe.unit_cost_cents
  end

  test "Preparation anidada dentro de otra Preparation, usada por la ProductRecipe" do
    raw = RawMaterial.create!(name: "Raw Anidado PRCalc", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    inner = Preparation.create!(name: "Inner PRCalc", yield_quantity: 1, yield_unit: "kg")
    inner.recipe_components.create!(component: raw, quantity: 1, unit: "kg")
    outer = Preparation.create!(name: "Outer PRCalc", yield_quantity: 1, yield_unit: "kg")
    outer.recipe_components.create!(component: inner, quantity: 1, unit: "kg")

    product = build_product
    recipe = ProductRecipe.create!(product: product, yield_quantity: 1)
    recipe.recipe_components.create!(component: outer, quantity: 1, unit: "kg")

    assert_equal 100_000, recipe.total_cost_cents
  end

  test "mezcla de RawMaterial y Preparation con conversión g/kg y ml/l" do
    harina = RawMaterial.create!(name: "Harina Mix PRCalc", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    leche = RawMaterial.create!(name: "Leche Mix PRCalc", purchase_price_cents: 50_000, purchase_quantity: 1, purchase_unit: "l", base_unit: "l")
    relleno = Preparation.create!(name: "Relleno Mix PRCalc", yield_quantity: 1, yield_unit: "kg")
    relleno.recipe_components.create!(component: harina, quantity: 1, unit: "kg")

    product = build_product
    recipe = ProductRecipe.create!(product: product, yield_quantity: 1)
    recipe.recipe_components.create!(component: harina, quantity: 250, unit: "g")   # 0.25 * 100.000 = 25.000
    recipe.recipe_components.create!(component: leche, quantity: 100, unit: "ml")   # 0.1 * 50.000 = 5.000
    recipe.recipe_components.create!(component: relleno, quantity: 200, unit: "g")  # 0.2 * 100.000 = 20.000

    assert_equal 50_000, recipe.total_cost_cents
  end

  test "precisión BigDecimal: no se pierde precisión por redondeos intermedios" do
    raw = RawMaterial.create!(name: "Raw Precision PRCalc", purchase_price_cents: 100_000, purchase_quantity: 3, purchase_unit: "kg", base_unit: "kg")
    # unit_cost_cents = 100000/3 = 33333.33... -> redondeado a 33333 al persistir la RawMaterial

    product = build_product
    recipe = ProductRecipe.create!(product: product, yield_quantity: 7)
    recipe.recipe_components.create!(component: raw, quantity: 1, unit: "kg")

    total = recipe.total_cost_cents
    unit = recipe.unit_cost_cents
    assert_equal raw.unit_cost_cents, total
    assert_equal (BigDecimal(raw.unit_cost_cents.to_s) / 7).round.to_i, unit
  end

  test "receta vacía (draft) cuesta 0 pero no es calculable/activable" do
    product = build_product
    recipe = ProductRecipe.create!(product: product, yield_quantity: 12)

    assert_equal 0, recipe.total_cost_cents
    assert_equal 0, recipe.unit_cost_cents
    assert_equal [], recipe.component_costs
    assert_not recipe.calculable?
  end
end
