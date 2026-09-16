require "test_helper"

class Costing::ActivateProductRecipeTest < ActiveSupport::TestCase
  def build_product(cost_cents: 165_000)
    category = Category.create!(name: "ActivateCat#{rand(1_000_000)}", position: 1, active: true)
    Product.create!(name: "Producto Activate #{rand(1_000_000)}", price_cents: 500_000,
      cost_cents: cost_cents, cost_source: "manual", category: category, active: true, position: 1)
  end

  test "activates a manual product with a calculable draft recipe, computing the current cost" do
    raw = RawMaterial.create!(name: "RM Activate", purchase_price_cents: 1_200_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    product = build_product
    recipe = ProductRecipe.create!(product: product, yield_quantity: 12)
    recipe.recipe_components.create!(component: raw, quantity: 1.2, unit: "kg")
    # total: 1_440_000 / 12 = 120_000

    result = Costing::ActivateProductRecipe.call(product)

    product.reload
    assert_equal 120_000, result
    assert product.recipe?
    assert_equal 120_000, product.cost_cents
  end

  test "raises and leaves the product untouched when there is no ProductRecipe yet" do
    product = build_product

    assert_raises(Costing::ActivateProductRecipe::ActivationError) { Costing::ActivateProductRecipe.call(product) }

    product.reload
    assert product.manual?
    assert_equal 165_000, product.cost_cents
  end

  test "raises and leaves the product untouched when the recipe has no components" do
    product = build_product
    ProductRecipe.create!(product: product, yield_quantity: 12)

    assert_raises(Costing::ActivateProductRecipe::ActivationError) { Costing::ActivateProductRecipe.call(product) }

    product.reload
    assert product.manual?
    assert_equal 165_000, product.cost_cents
  end

  test "raises and leaves the product untouched when yield_quantity would be invalid" do
    raw = RawMaterial.create!(name: "RM Activate Invalid Yield", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    product = build_product
    recipe = ProductRecipe.create!(product: product, yield_quantity: 12)
    recipe.recipe_components.create!(component: raw, quantity: 1, unit: "kg")
    recipe.update_column(:yield_quantity, 0) # bypass validation to simulate corrupted data

    assert_raises(Costing::ActivateProductRecipe::ActivationError) { Costing::ActivateProductRecipe.call(product) }

    product.reload
    assert product.manual?
    assert_equal 165_000, product.cost_cents
  end

  test "raises and leaves the product untouched when a directly-used Preparation is empty" do
    empty_prep = Preparation.create!(name: "Ganache Limón Activate", yield_quantity: 1, yield_unit: "kg")
    product = build_product
    recipe = ProductRecipe.create!(product: product, yield_quantity: 12)
    recipe.recipe_components.create!(component: empty_prep, quantity: 1, unit: "kg")

    error = assert_raises(Costing::ActivateProductRecipe::ActivationError) { Costing::ActivateProductRecipe.call(product) }
    assert_match(/Ganache Limón Activate/, error.message)

    product.reload
    assert product.manual?
    assert_equal 165_000, product.cost_cents
  end

  test "raises and leaves the product untouched when a nested (indirectly-used) Preparation is empty" do
    raw = RawMaterial.create!(name: "RM Activate Nested", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    empty_inner = Preparation.create!(name: "Ganache Interna Activate", yield_quantity: 1, yield_unit: "kg")
    masa_sable = Preparation.create!(name: "Masa Sable Activate", yield_quantity: 1, yield_unit: "kg")
    masa_sable.recipe_components.create!(component: empty_inner, quantity: 1, unit: "kg")

    product = build_product
    recipe = ProductRecipe.create!(product: product, yield_quantity: 12)
    recipe.recipe_components.create!(component: masa_sable, quantity: 1, unit: "kg")

    error = assert_raises(Costing::ActivateProductRecipe::ActivationError) { Costing::ActivateProductRecipe.call(product) }
    assert_match(/Ganache Interna Activate/, error.message)

    product.reload
    assert product.manual?
    assert_equal 165_000, product.cost_cents
  end

  test "a legitimate $0 cost anywhere in the graph does not block activation" do
    free_raw = RawMaterial.create!(name: "RM Activate Free", purchase_price_cents: 0, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    free_prep = Preparation.create!(name: "Prep Activate Free", yield_quantity: 1, yield_unit: "kg")
    free_prep.recipe_components.create!(component: free_raw, quantity: 1, unit: "kg")

    product = build_product
    recipe = ProductRecipe.create!(product: product, yield_quantity: 1)
    recipe.recipe_components.create!(component: free_prep, quantity: 1, unit: "kg")

    Costing::ActivateProductRecipe.call(product)

    product.reload
    assert product.recipe?
    assert_equal 0, product.cost_cents
  end
end
