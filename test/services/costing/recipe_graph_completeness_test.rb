require "test_helper"

class Costing::RecipeGraphCompletenessTest < ActiveSupport::TestCase
  def build_product
    category = Category.create!(name: "GraphCompletenessCat#{rand(1_000_000)}", position: 1, active: true)
    Product.create!(name: "Producto GraphCompleteness #{rand(1_000_000)}", price_cents: 500_000,
      cost_cents: 1, cost_source: "manual", category: category, active: true, position: 1)
  end

  test "raises when the ProductRecipe itself has no components" do
    recipe = ProductRecipe.create!(product: build_product, yield_quantity: 1)

    error = assert_raises(Costing::RecipeGraphCompleteness::IncompleteGraphError) do
      Costing::RecipeGraphCompleteness.check!(recipe)
    end
    assert_match(/no tiene componentes/, error.message)
  end

  test "raises when a directly-used Preparation is empty" do
    empty_prep = Preparation.create!(name: "Ganache Vacio GraphCompleteness", yield_quantity: 1, yield_unit: "kg")
    recipe = ProductRecipe.create!(product: build_product, yield_quantity: 1)
    recipe.recipe_components.create!(component: empty_prep, quantity: 1, unit: "kg")

    error = assert_raises(Costing::RecipeGraphCompleteness::IncompleteGraphError) do
      Costing::RecipeGraphCompleteness.check!(recipe)
    end
    assert_match(/Ganache Vacio GraphCompleteness/, error.message)
  end

  test "raises when an indirectly-used (nested) Preparation is empty" do
    raw = RawMaterial.create!(name: "RM GraphCompleteness Nested", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    inner_empty = Preparation.create!(name: "Inner Vacio GraphCompleteness", yield_quantity: 1, yield_unit: "kg")
    outer = Preparation.create!(name: "Outer GraphCompleteness", yield_quantity: 1, yield_unit: "kg")
    outer.recipe_components.create!(component: inner_empty, quantity: 1, unit: "kg")

    recipe = ProductRecipe.create!(product: build_product, yield_quantity: 1)
    recipe.recipe_components.create!(component: outer, quantity: 1, unit: "kg")

    error = assert_raises(Costing::RecipeGraphCompleteness::IncompleteGraphError) do
      Costing::RecipeGraphCompleteness.check!(recipe)
    end
    assert_match(/Inner Vacio GraphCompleteness/, error.message)

    inner_empty.recipe_components.create!(component: raw, quantity: 1, unit: "kg")
    assert_nothing_raised { Costing::RecipeGraphCompleteness.check!(recipe) }
  end

  test "passes when every reachable Preparation has at least one component, regardless of cost" do
    free_raw = RawMaterial.create!(name: "RM GraphCompleteness Free", purchase_price_cents: 0, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    prep = Preparation.create!(name: "Prep GraphCompleteness Free", yield_quantity: 1, yield_unit: "kg")
    prep.recipe_components.create!(component: free_raw, quantity: 1, unit: "kg")
    assert_equal 0, prep.unit_cost_cents

    recipe = ProductRecipe.create!(product: build_product, yield_quantity: 1)
    recipe.recipe_components.create!(component: prep, quantity: 1, unit: "kg")

    assert_nothing_raised { Costing::RecipeGraphCompleteness.check!(recipe) }
  end

  test "does not inspect RawMaterial components for emptiness (only Preparations have a component graph)" do
    raw = RawMaterial.create!(name: "RM GraphCompleteness Direct", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    recipe = ProductRecipe.create!(product: build_product, yield_quantity: 1)
    recipe.recipe_components.create!(component: raw, quantity: 1, unit: "kg")

    assert_nothing_raised { Costing::RecipeGraphCompleteness.check!(recipe) }
  end

  test "a corrupted cycle does not cause infinite recursion (bails silently, cost calculation reports the cycle separately)" do
    raw = RawMaterial.create!(name: "RM GraphCompleteness Cycle", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    a = Preparation.create!(name: "CycleA GraphCompleteness", yield_quantity: 1, yield_unit: "kg")
    b = Preparation.create!(name: "CycleB GraphCompleteness", yield_quantity: 1, yield_unit: "kg")
    a.recipe_components.create!(component: b, quantity: 1, unit: "kg")
    b.recipe_components.create!(component: raw, quantity: 1, unit: "kg")
    corrupt = b.recipe_components.build(component: a, quantity: 1, unit: "kg")
    corrupt.save!(validate: false) # datos corruptos a propósito, bypasseando la validación de ciclos

    recipe = ProductRecipe.create!(product: build_product, yield_quantity: 1)
    recipe.recipe_components.create!(component: a, quantity: 1, unit: "kg")

    assert_nothing_raised { Costing::RecipeGraphCompleteness.check!(recipe) }
    assert_raises(Costing::PreparationCalculator::CircularDependencyError) { recipe.unit_cost_cents }
  end
end
