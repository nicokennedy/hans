require "test_helper"

class Admin::ProductRecipeComponentsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = User.create!(email: "productrecipecomponents-admin@example.com", password: "password123", role: "admin")
    sign_in @admin

    @category = Category.create!(name: "PRComponentsCtrlCat#{rand(1_000_000)}", position: 1, active: true)
    @raw_material = RawMaterial.create!(name: "RM PRComponentsCtrl", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    @product = Product.create!(name: "Producto PRComponentsCtrl #{rand(1_000_000)}", price_cents: 500_000,
      cost_cents: 1, cost_source: "manual", category: @category, active: true, position: 1)
    @recipe = ProductRecipe.create!(product: @product, yield_quantity: 10)
  end

  test "admin can add a raw material component to a draft recipe" do
    assert_difference "@recipe.recipe_components.count", 1 do
      post admin_product_product_recipe_recipe_components_path(@product), params: {
        recipe_component: { component_ref: "RawMaterial:#{@raw_material.id}", quantity: "500", unit: "g" }
      }
    end

    assert_redirected_to edit_admin_product_product_recipe_path(@product)
    assert_equal 50_000, @recipe.reload.total_cost_cents
  end

  test "adding an incompatible-unit component is rejected, server-side" do
    assert_no_difference "RecipeComponent.count" do
      post admin_product_product_recipe_recipe_components_path(@product), params: {
        recipe_component: { component_ref: "RawMaterial:#{@raw_material.id}", quantity: "1", unit: "ml" }
      }
    end

    assert_redirected_to edit_admin_product_product_recipe_path(@product)
  end

  test "updating quantity/unit of an active recipe's component recalculates the product cost automatically" do
    recipe_component = @recipe.recipe_components.create!(component: @raw_material, quantity: 1, unit: "kg")
    Costing::ActivateProductRecipe.call(@product)
    assert_equal 10_000, @product.reload.cost_cents # 100.000 / 10

    patch admin_product_product_recipe_recipe_component_path(@product, recipe_component), params: { recipe_component: { quantity: "2", unit: "kg" } }

    assert_redirected_to edit_admin_product_product_recipe_path(@product)
    assert_equal 20_000, @product.reload.cost_cents
  end

  test "admin can remove a component from a draft recipe without touching the manual product cost" do
    recipe_component = @recipe.recipe_components.create!(component: @raw_material, quantity: 1, unit: "kg")

    assert_difference "RecipeComponent.count", -1 do
      delete admin_product_product_recipe_recipe_component_path(@product, recipe_component)
    end

    assert_redirected_to edit_admin_product_product_recipe_path(@product)
    assert RawMaterial.exists?(@raw_material.id)
  end

  test "deleting the last component of an ACTIVE recipe is rejected, and the product keeps its previous cost" do
    recipe_component = @recipe.recipe_components.create!(component: @raw_material, quantity: 1, unit: "kg")
    Costing::ActivateProductRecipe.call(@product)
    original_cost = @product.reload.cost_cents

    assert_no_difference "RecipeComponent.count" do
      delete admin_product_product_recipe_recipe_component_path(@product, recipe_component)
    end

    assert_redirected_to edit_admin_product_product_recipe_path(@product)
    assert flash[:alert].present?
    assert_equal original_cost, @product.reload.cost_cents
    assert RecipeComponent.exists?(recipe_component.id)
  end

  test "deleting one of several components of an active recipe (not the last) recalculates normally" do
    other_raw = RawMaterial.create!(name: "RM PRComponentsCtrl Other", purchase_price_cents: 50_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    recipe_component = @recipe.recipe_components.create!(component: @raw_material, quantity: 1, unit: "kg")
    other_component = @recipe.recipe_components.create!(component: other_raw, quantity: 1, unit: "kg")
    Costing::ActivateProductRecipe.call(@product)
    assert_equal 15_000, @product.reload.cost_cents # (100.000 + 50.000) / 10

    assert_difference "RecipeComponent.count", -1 do
      delete admin_product_product_recipe_recipe_component_path(@product, other_component)
    end

    assert_redirected_to edit_admin_product_product_recipe_path(@product)
    assert_equal 10_000, @product.reload.cost_cents # 100.000 / 10
  end
end
