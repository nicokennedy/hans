require "test_helper"

class Admin::RecipesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = User.create!(email: "recipes-admin@example.com", password: "password123", role: "admin")
    sign_in @admin

    @category = Category.create!(name: "RecipesCtrlCat#{rand(1_000_000)}", position: 1, active: true)
    @raw_material = RawMaterial.create!(name: "RM RecipesCtrl", purchase_price_cents: 1_000_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
  end

  test "does not duplicate Product — indexes the same existing products, just with recipe state" do
    product = Product.create!(name: "Producto RecipesCtrl Sin Receta", price_cents: 100_000, cost_cents: 50_000,
      category: @category, active: true, position: 1)

    assert_no_difference "Product.count" do
      get admin_recipes_path
    end

    assert_response :success
    assert_match product.name, response.body
  end

  test "shows 'Sin receta' for a Product without a ProductRecipe, with a 'Crear receta' action" do
    product = Product.create!(name: "Producto RecipesCtrl Sin Receta2", price_cents: 100_000, cost_cents: 50_000,
      category: @category, active: true, position: 1)

    get admin_recipes_path

    assert_response :success
    assert_match "Sin receta", response.body
    assert_match "Crear receta", response.body
    assert_select "a[href=?]", new_admin_product_product_recipe_path(product)
  end

  test "shows 'Borrador' for a Product with a ProductRecipe while cost_source is manual, with an 'Editar receta' action" do
    product = Product.create!(name: "Producto RecipesCtrl Borrador", price_cents: 100_000, cost_cents: 50_000,
      category: @category, cost_source: "manual", active: true, position: 1)
    ProductRecipe.create!(product: product, yield_quantity: 10)

    get admin_recipes_path

    assert_response :success
    assert_match "Borrador", response.body
    assert_select "a[href=?]", edit_admin_product_product_recipe_path(product), text: "Editar receta"
  end

  test "shows 'Activa' for a Product with cost_source recipe, with an 'Editar receta' action and the calculated cost" do
    product = Product.create!(name: "Producto RecipesCtrl Activa", price_cents: 100_000, cost_cents: 1,
      category: @category, cost_source: "manual", active: true, position: 1)
    recipe = ProductRecipe.create!(product: product, yield_quantity: 10)
    recipe.recipe_components.create!(component: @raw_material, quantity: 1, unit: "kg")
    Costing::ActivateProductRecipe.call(product)

    get admin_recipes_path

    assert_response :success
    assert_match "Activa", response.body
    assert_match "$1,000", response.body # costo por unidad calculado: $10.000 / 10 (format_money usa coma como separador de miles)
    assert_select "a[href=?]", edit_admin_product_product_recipe_path(product), text: "Editar receta"
  end
end
