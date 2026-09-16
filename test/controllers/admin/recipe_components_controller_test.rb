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
end
