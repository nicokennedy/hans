require "test_helper"

class Admin::ProductRecipesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = User.create!(email: "productrecipes-admin@example.com", password: "password123", role: "admin")
    sign_in @admin

    @category = Category.create!(name: "ProductRecipeCtrlCat#{rand(1_000_000)}", position: 1, active: true)
    @raw_material = RawMaterial.create!(name: "RM ProductRecipeCtrl", purchase_price_cents: 1_000_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    @product = Product.create!(name: "Producto ProductRecipeCtrl #{rand(1_000_000)}", price_cents: 500_000,
      cost_cents: 150_000, cost_source: "manual", category: @category, active: true, position: 1)
  end

  test "admin can view the new recipe form for a product without one, with a components section" do
    get new_admin_product_product_recipe_path(@product)
    assert_response :success
    assert_match "Componentes", response.body
    assert_match "+ Agregar componente", response.body
  end

  test "admin can create a draft recipe without affecting the manual product cost" do
    assert_difference "ProductRecipe.count", 1 do
      post admin_product_product_recipe_path(@product), params: { product_recipe: { yield_quantity: "12" } }
    end

    assert_redirected_to edit_admin_product_product_recipe_path(@product)
    assert_equal 150_000, @product.reload.cost_cents
    assert @product.manual?
  end

  test "admin can create a ProductRecipe with multiple components in the same submit" do
    masa_sable = Preparation.create!(name: "Masa Sable ProductRecipeCtrl New", yield_quantity: 1, yield_unit: "kg")
    masa_sable.recipe_components.create!(component: @raw_material, quantity: 1, unit: "kg")
    limon = RawMaterial.create!(name: "Limon ProductRecipeCtrl New", purchase_price_cents: 400_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")

    assert_difference "ProductRecipe.count", 1 do
      post admin_product_product_recipe_path(@product), params: {
        product_recipe: { yield_quantity: "12" },
        recipe_components: [
          { component_ref: "Preparation:#{masa_sable.id}", quantity: "0.5", unit: "kg" },
          { component_ref: "RawMaterial:#{limon.id}", quantity: "0.4", unit: "kg" }
        ]
      }
    end

    assert_redirected_to edit_admin_product_product_recipe_path(@product)
    product_recipe = @product.reload.product_recipe
    assert_equal 2, product_recipe.recipe_components.count
    assert_equal 150_000, @product.cost_cents, "manual product cost must stay untouched by creating the recipe"
  end

  test "a new ProductRecipe admits a mix of RawMaterial and Preparation components" do
    masa_sable = Preparation.create!(name: "Masa Sable ProductRecipeCtrl Mix", yield_quantity: 1, yield_unit: "kg")
    masa_sable.recipe_components.create!(component: @raw_material, quantity: 1, unit: "kg")

    post admin_product_product_recipe_path(@product), params: {
      product_recipe: { yield_quantity: "12" },
      recipe_components: [
        { component_ref: "Preparation:#{masa_sable.id}", quantity: "0.5", unit: "kg" },
        { component_ref: "RawMaterial:#{@raw_material.id}", quantity: "0.4", unit: "kg" }
      ]
    }

    product_recipe = @product.reload.product_recipe
    assert_equal %w[Preparation RawMaterial], product_recipe.recipe_components.map(&:component_type).sort
  end

  test "a ProductRecipe cannot include a Product/ProductRecipe as a component (structurally impossible via the selector)" do
    other_product = Product.create!(name: "Otro Producto ProductRecipeCtrl", price_cents: 100_000, cost_cents: 50_000, category: @category, active: true, position: 2)

    post admin_product_product_recipe_path(@product), params: {
      product_recipe: { yield_quantity: "12" },
      recipe_components: [
        { component_ref: "Product:#{other_product.id}", quantity: "1", unit: "un" }
      ]
    }

    assert_response :unprocessable_entity
    assert_nil @product.reload.product_recipe
  end

  test "admin can edit yield_quantity of a draft recipe; while manual, the product cost is untouched" do
    recipe = ProductRecipe.create!(product: @product, yield_quantity: 10)
    recipe.recipe_components.create!(component: @raw_material, quantity: 1, unit: "kg")

    patch admin_product_product_recipe_path(@product), params: { product_recipe: { yield_quantity: "5" } }

    assert_redirected_to edit_admin_product_product_recipe_path(@product)
    assert_equal 5, recipe.reload.yield_quantity.to_i
    assert_equal 150_000, @product.reload.cost_cents
  end

  test "editing yield_quantity of an ACTIVE recipe recalculates the product cost automatically" do
    recipe = ProductRecipe.create!(product: @product, yield_quantity: 10)
    recipe.recipe_components.create!(component: @raw_material, quantity: 1, unit: "kg")
    Costing::ActivateProductRecipe.call(@product)
    assert_equal 100_000, @product.reload.cost_cents

    patch admin_product_product_recipe_path(@product), params: { product_recipe: { yield_quantity: "5" } }

    assert_redirected_to edit_admin_product_product_recipe_path(@product)
    assert_equal 200_000, @product.reload.cost_cents
  end

  test "activating a calculable draft recipe changes cost_source and cost_cents atomically" do
    recipe = ProductRecipe.create!(product: @product, yield_quantity: 10)
    recipe.recipe_components.create!(component: @raw_material, quantity: 1, unit: "kg")

    post activate_admin_product_product_recipe_path(@product)

    assert_redirected_to edit_admin_product_path(@product)
    @product.reload
    assert @product.recipe?
    assert_equal 100_000, @product.cost_cents
  end

  test "activating an incomplete recipe is rejected with an understandable error, and nothing changes" do
    ProductRecipe.create!(product: @product, yield_quantity: 10) # sin componentes

    post activate_admin_product_product_recipe_path(@product)

    assert_redirected_to edit_admin_product_product_recipe_path(@product)
    assert flash[:alert].present?
    @product.reload
    assert @product.manual?
    assert_equal 150_000, @product.cost_cents
  end

  test "deactivating a recipe preserves the last cost as the new manual value, and keeps the ProductRecipe" do
    recipe = ProductRecipe.create!(product: @product, yield_quantity: 10)
    recipe.recipe_components.create!(component: @raw_material, quantity: 1, unit: "kg")
    Costing::ActivateProductRecipe.call(@product)
    assert_equal 100_000, @product.reload.cost_cents

    post deactivate_admin_product_product_recipe_path(@product)

    assert_redirected_to edit_admin_product_path(@product)
    @product.reload
    assert @product.manual?
    assert_equal 100_000, @product.cost_cents
    assert ProductRecipe.exists?(recipe.id)
  end
end
