require "test_helper"

class Admin::PreparationsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = User.create!(email: "preparations-admin@example.com", password: "password123", role: "admin")
    sign_in @admin

    @harina = RawMaterial.create!(name: "Harina PrepCtrl", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    @preparation = Preparation.create!(name: "Masa Sable PrepCtrl", yield_quantity: 2, yield_unit: "kg")
    @preparation.recipe_components.create!(component: @harina, quantity: 1000, unit: "g")
  end

  test "admin can view the index, with computed total/unit cost" do
    get admin_preparations_path

    assert_response :success
    assert_match "Masa Sable PrepCtrl", response.body
  end

  test "admin can view the new form" do
    get new_admin_preparation_path
    assert_response :success
  end

  test "admin can create a preparation without components" do
    assert_difference "Preparation.count", 1 do
      post admin_preparations_path, params: { preparation: { name: "Nueva PrepCtrl", yield_quantity: "1.5", yield_unit: "kg", active: "1" } }
    end

    assert_redirected_to admin_preparations_path
    preparation = Preparation.find_by!(name: "Nueva PrepCtrl")
    assert_equal 0, preparation.recipe_components.count
    assert_equal 0, preparation.total_cost_cents
  end

  test "creating with an invalid yield_unit re-renders the form with a clear error, server-side" do
    assert_no_difference "Preparation.count" do
      post admin_preparations_path, params: { preparation: { name: "Invalida", yield_quantity: "1", yield_unit: "g", active: "1" } }
    end

    assert_response :unprocessable_entity
  end

  test "admin can view the edit form, including components and computed costs" do
    get edit_admin_preparation_path(@preparation)

    assert_response :success
    assert_match "Harina PrepCtrl", response.body
    assert_match "Componentes", response.body
    assert_match "Agregar componente", response.body
  end

  test "admin can update a preparation's own fields (name/yield), without touching its components" do
    patch admin_preparation_path(@preparation), params: { preparation: { name: "Masa Sable Editada", yield_quantity: "2", yield_unit: "kg" } }

    assert_redirected_to admin_preparations_path
    @preparation.reload
    assert_equal "Masa Sable Editada", @preparation.name
    assert_equal 1, @preparation.recipe_components.count
  end

  test "an invalid update re-renders the edit form with components still visible" do
    patch admin_preparation_path(@preparation), params: { preparation: { yield_quantity: "0" } }

    assert_response :unprocessable_entity
    assert_match "Harina PrepCtrl", response.body
  end

  test "updating only the name does NOT recalculate downstream products (no cost-relevant change)" do
    category = Category.create!(name: "PrepCtrlPropCat#{rand(1_000_000)}", position: 1, active: true)
    product = Product.create!(name: "Producto PrepCtrlProp #{rand(1_000_000)}", price_cents: 500_000,
      cost_cents: 1, cost_source: "manual", category: category, active: true, position: 1)
    recipe = ProductRecipe.create!(product: product, yield_quantity: 1)
    recipe.recipe_components.create!(component: @preparation, quantity: 1, unit: "kg")
    Costing::ActivateProductRecipe.call(product)
    original_cost = product.reload.cost_cents

    patch admin_preparation_path(@preparation), params: { preparation: { name: "Masa Sable Renombrada", yield_quantity: @preparation.yield_quantity, yield_unit: @preparation.yield_unit } }

    assert_redirected_to admin_preparations_path
    assert_equal original_cost, product.reload.cost_cents
  end

  test "changing yield_quantity DOES recalculate downstream products automatically" do
    category = Category.create!(name: "PrepCtrlYieldCat#{rand(1_000_000)}", position: 1, active: true)
    product = Product.create!(name: "Producto PrepCtrlYield #{rand(1_000_000)}", price_cents: 500_000,
      cost_cents: 1, cost_source: "manual", category: category, active: true, position: 1)
    recipe = ProductRecipe.create!(product: product, yield_quantity: 1)
    recipe.recipe_components.create!(component: @preparation, quantity: 1, unit: "kg")
    Costing::ActivateProductRecipe.call(product)
    assert_equal 50_000, product.reload.cost_cents # 100.000 total / 2kg yield

    patch admin_preparation_path(@preparation), params: { preparation: { name: @preparation.name, yield_quantity: "1", yield_unit: "kg" } }

    assert_redirected_to admin_preparations_path
    assert_equal 100_000, product.reload.cost_cents # mismo total / 1kg yield ahora
  end

  test "a corrupted circular dependency (bypassing validations) does not crash the index or edit pages, and stays fixable" do
    a = Preparation.create!(name: "CorruptA PrepCtrl", yield_quantity: 1, yield_unit: "kg")
    b = Preparation.create!(name: "CorruptB PrepCtrl", yield_quantity: 1, yield_unit: "kg")
    a.recipe_components.create!(component: b, quantity: 1, unit: "kg")
    corrupt = b.recipe_components.build(component: a, quantity: 1, unit: "kg")
    corrupt.save!(validate: false) # simula datos corruptos: salteamos la validación de ciclos a propósito

    get admin_preparations_path
    assert_response :success
    assert_match "CorruptA PrepCtrl", response.body
    assert_match "—", response.body # costo no calculable, mostrado sin romper la página

    get edit_admin_preparation_path(a)
    assert_response :success
    assert_match(/Ciclo detectado/, response.body)

    # el camino de reparación sigue disponible: se puede eliminar el
    # componente que cierra el ciclo sin que la página se caiga antes.
    assert_difference "RecipeComponent.count", -1 do
      delete admin_preparation_recipe_component_path(b, corrupt)
    end
    assert_redirected_to edit_admin_preparation_path(b)

    get edit_admin_preparation_path(a)
    assert_response :success
    assert_no_match(/Ciclo detectado/, response.body)
  end
end
