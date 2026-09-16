require "test_helper"

class Costing::RecalculateAllRecipeProductsTest < ActiveSupport::TestCase
  def build_recipe_product(cost_cents:, yield_quantity: 1)
    category = Category.create!(name: "RecalcAllCat#{rand(1_000_000)}", position: 1, active: true)
    product = Product.create!(name: "Producto RecalcAll #{rand(1_000_000)}", price_cents: 500_000,
      cost_cents: cost_cents, cost_source: "manual", category: category, active: true, position: 1)
    recipe = ProductRecipe.create!(product: product, yield_quantity: yield_quantity)
    [product, recipe]
  end

  test "recalculates only products with cost_source recipe, leaving manual products (even with a draft recipe) untouched" do
    raw = RawMaterial.create!(name: "RM RecalcAll", purchase_price_cents: 500_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")

    product_a, recipe_a = build_recipe_product(cost_cents: 1)
    recipe_a.recipe_components.create!(component: raw, quantity: 1, unit: "kg")
    Costing::ActivateProductRecipe.call(product_a)

    product_b, recipe_b = build_recipe_product(cost_cents: 1, yield_quantity: 5)
    recipe_b.recipe_components.create!(component: raw, quantity: 1, unit: "kg")
    Costing::ActivateProductRecipe.call(product_b)

    product_c, recipe_c = build_recipe_product(cost_cents: 77_000) # queda manual a propósito
    recipe_c.recipe_components.create!(component: raw, quantity: 1, unit: "kg")

    # Corrompemos A y B directamente en la base, saltando todo el motor de
    # costeo — simula el escenario que la herramienta de reparación existe
    # para arreglar (datos desincronizados por cualquier causa externa).
    Product.where(id: [product_a.id, product_b.id]).update_all(cost_cents: 1)

    result = Costing::RecalculateAllRecipeProducts.call

    assert_equal 2, result.recalculated
    assert_equal [], result.errors
    assert_equal 500_000, product_a.reload.cost_cents
    assert_equal 100_000, product_b.reload.cost_cents
    assert_equal 77_000, product_c.reload.cost_cents
    assert product_c.manual?
  end

  test "a single unfixable recipe does not block recalculating the rest, and is reported as an error" do
    raw = RawMaterial.create!(name: "RM RecalcAll Broken", purchase_price_cents: 200_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")

    healthy_product, healthy_recipe = build_recipe_product(cost_cents: 1)
    healthy_recipe.recipe_components.create!(component: raw, quantity: 1, unit: "kg")
    Costing::ActivateProductRecipe.call(healthy_product)

    broken_product, broken_recipe = build_recipe_product(cost_cents: 1)
    broken_recipe.recipe_components.create!(component: raw, quantity: 1, unit: "kg")
    Costing::ActivateProductRecipe.call(broken_product)
    # Corrompemos la receta activa dejándola sin componentes, saltando el
    # camino normal (que lo rechazaría) — simula datos corruptos reales.
    broken_recipe.recipe_components.delete_all

    Product.where(id: [healthy_product.id, broken_product.id]).update_all(cost_cents: 1)

    result = Costing::RecalculateAllRecipeProducts.call

    assert_equal 1, result.recalculated
    assert_equal 1, result.errors.size
    assert_match(/Product##{broken_product.id}/, result.errors.first)
    assert_equal 200_000, healthy_product.reload.cost_cents
    assert_equal 1, broken_product.reload.cost_cents
  end
end
