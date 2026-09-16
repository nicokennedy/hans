require "test_helper"

class Admin::RecipeComponentsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = User.create!(email: "recipecomponents-admin@example.com", password: "password123", role: "admin")
    sign_in @admin

    @harina = RawMaterial.create!(name: "Harina RCCtrl", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    @preparation = Preparation.create!(name: "Masa RCCtrl", yield_quantity: 1, yield_unit: "kg")
  end

  test "admin can add a raw material component" do
    assert_difference "@preparation.recipe_components.count", 1 do
      post admin_preparation_recipe_components_path(@preparation), params: {
        recipe_component: { component_ref: "RawMaterial:#{@harina.id}", quantity: "500", unit: "g" }
      }
    end

    assert_redirected_to edit_admin_preparation_path(@preparation)
    assert_equal 50_000, @preparation.reload.total_cost_cents
  end

  test "admin can add a preparation component" do
    child = Preparation.create!(name: "Child RCCtrl", yield_quantity: 1, yield_unit: "kg")
    child.recipe_components.create!(component: @harina, quantity: 1, unit: "kg")

    assert_difference "@preparation.recipe_components.count", 1 do
      post admin_preparation_recipe_components_path(@preparation), params: {
        recipe_component: { component_ref: "Preparation:#{child.id}", quantity: "500", unit: "g" }
      }
    end

    assert_equal 50_000, @preparation.reload.total_cost_cents
  end

  test "adding an incompatible-unit component is rejected, server-side" do
    assert_no_difference "RecipeComponent.count" do
      post admin_preparation_recipe_components_path(@preparation), params: {
        recipe_component: { component_ref: "RawMaterial:#{@harina.id}", quantity: "1", unit: "ml" }
      }
    end

    assert_redirected_to edit_admin_preparation_path(@preparation)
  end

  test "adding a component that would introduce a cycle is rejected, server-side" do
    a = Preparation.create!(name: "CycleCtrlA", yield_quantity: 1, yield_unit: "kg")
    b = Preparation.create!(name: "CycleCtrlB", yield_quantity: 1, yield_unit: "kg")
    a.recipe_components.create!(component: b, quantity: 1, unit: "kg")

    assert_no_difference "RecipeComponent.count" do
      post admin_preparation_recipe_components_path(b), params: {
        recipe_component: { component_ref: "Preparation:#{a.id}", quantity: "1", unit: "kg" }
      }
    end

    assert_redirected_to edit_admin_preparation_path(b)
  end

  test "admin can update quantity/unit of an existing component, and the preparation's cost recalculates" do
    recipe_component = @preparation.recipe_components.create!(component: @harina, quantity: 1000, unit: "g")

    patch admin_preparation_recipe_component_path(@preparation, recipe_component), params: { recipe_component: { quantity: "500", unit: "g" } }

    assert_redirected_to edit_admin_preparation_path(@preparation)
    assert_equal 500, recipe_component.reload.quantity.to_i
    assert_equal 50_000, @preparation.reload.total_cost_cents
  end

  test "admin can remove a component without destroying the referenced raw material" do
    recipe_component = @preparation.recipe_components.create!(component: @harina, quantity: 1000, unit: "g")

    assert_difference "RecipeComponent.count", -1 do
      delete admin_preparation_recipe_component_path(@preparation, recipe_component)
    end

    assert_redirected_to edit_admin_preparation_path(@preparation)
    assert RawMaterial.exists?(@harina.id)
    assert_equal 0, @preparation.reload.total_cost_cents
  end

  test "deleting the last component of a Preparation used by an ACTIVE ProductRecipe is rejected; the component and the product's cost survive" do
    recipe_component = @preparation.recipe_components.create!(component: @harina, quantity: 1000, unit: "g")

    category = Category.create!(name: "RCCtrlActiveCat#{rand(1_000_000)}", position: 1, active: true)
    product = Product.create!(name: "Producto RCCtrlActive #{rand(1_000_000)}", price_cents: 500_000,
      cost_cents: 1, cost_source: "manual", category: category, active: true, position: 1)
    product_recipe = ProductRecipe.create!(product: product, yield_quantity: 1)
    product_recipe.recipe_components.create!(component: @preparation, quantity: 1, unit: "kg")
    Costing::ActivateProductRecipe.call(product)
    original_cost = product.reload.cost_cents

    assert_no_difference "RecipeComponent.count" do
      delete admin_preparation_recipe_component_path(@preparation, recipe_component)
    end

    assert_redirected_to edit_admin_preparation_path(@preparation)
    assert flash[:alert].present?
    assert RecipeComponent.exists?(recipe_component.id)
    assert_equal 1, @preparation.reload.recipe_components.count
    assert_equal original_cost, product.reload.cost_cents
  end

  test "the rejection also applies through a two-level nested Preparation chain" do
    recipe_component = @preparation.recipe_components.create!(component: @harina, quantity: 1000, unit: "g")
    outer = Preparation.create!(name: "Outer RCCtrl", yield_quantity: 1, yield_unit: "kg")
    outer.recipe_components.create!(component: @preparation, quantity: 1, unit: "kg")

    category = Category.create!(name: "RCCtrlNestedCat#{rand(1_000_000)}", position: 1, active: true)
    product = Product.create!(name: "Producto RCCtrlNested #{rand(1_000_000)}", price_cents: 500_000,
      cost_cents: 1, cost_source: "manual", category: category, active: true, position: 1)
    product_recipe = ProductRecipe.create!(product: product, yield_quantity: 1)
    product_recipe.recipe_components.create!(component: outer, quantity: 1, unit: "kg")
    Costing::ActivateProductRecipe.call(product)
    original_cost = product.reload.cost_cents

    assert_no_difference "RecipeComponent.count" do
      delete admin_preparation_recipe_component_path(@preparation, recipe_component)
    end

    assert_redirected_to edit_admin_preparation_path(@preparation)
    assert flash[:alert].present?
    assert RecipeComponent.exists?(recipe_component.id)
    assert_equal 1, @preparation.reload.recipe_components.count
    assert_equal original_cost, product.reload.cost_cents
  end

  test "the same deletion is permitted when no active ProductRecipe depends on the Preparation" do
    recipe_component = @preparation.recipe_components.create!(component: @harina, quantity: 1000, unit: "g")

    assert_difference "RecipeComponent.count", -1 do
      delete admin_preparation_recipe_component_path(@preparation, recipe_component)
    end

    assert_redirected_to edit_admin_preparation_path(@preparation)
    assert_not RecipeComponent.exists?(recipe_component.id)
  end
end
