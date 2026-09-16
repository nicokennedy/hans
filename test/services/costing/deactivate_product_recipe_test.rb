require "test_helper"

class Costing::DeactivateProductRecipeTest < ActiveSupport::TestCase
  test "moves a recipe-sourced product back to manual, preserving the last cost as the new manual starting point" do
    category = Category.create!(name: "DeactivateCat#{rand(1_000_000)}", position: 1, active: true)
    raw = RawMaterial.create!(name: "RM Deactivate", purchase_price_cents: 1_500_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    product = Product.create!(name: "Producto Deactivate #{rand(1_000_000)}", price_cents: 500_000,
      cost_cents: 100_000, cost_source: "manual", category: category, active: true, position: 1)
    recipe = ProductRecipe.create!(product: product, yield_quantity: 10)
    recipe.recipe_components.create!(component: raw, quantity: 1, unit: "kg")

    Costing::ActivateProductRecipe.call(product)
    product.reload
    assert product.recipe?
    assert_equal 150_000, product.cost_cents

    result = Costing::DeactivateProductRecipe.call(product)
    product.reload

    assert_equal 150_000, result
    assert product.manual?
    assert_equal 150_000, product.cost_cents
  end

  test "does not delete the ProductRecipe — it stays saved and reactivatable" do
    category = Category.create!(name: "DeactivateKeepCat#{rand(1_000_000)}", position: 1, active: true)
    raw = RawMaterial.create!(name: "RM Deactivate Keep", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    product = Product.create!(name: "Producto Deactivate Keep #{rand(1_000_000)}", price_cents: 500_000,
      cost_cents: 50_000, cost_source: "manual", category: category, active: true, position: 1)
    recipe = ProductRecipe.create!(product: product, yield_quantity: 10)
    recipe.recipe_components.create!(component: raw, quantity: 1, unit: "kg")

    Costing::ActivateProductRecipe.call(product)
    Costing::DeactivateProductRecipe.call(product)

    assert ProductRecipe.exists?(recipe.id)
    assert_equal recipe.id, product.reload.product_recipe.id

    Costing::ActivateProductRecipe.call(product)
    assert product.reload.recipe?
  end
end
