require "test_helper"

class Admin::RawMaterialsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = User.create!(email: "rawmaterials-admin@example.com", password: "password123", role: "admin")
    sign_in @admin

    @raw_material = RawMaterial.create!(
      name: "Manteca", category: "Lácteos", brand: "La Paulina", supplier: "Reposmar",
      purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg"
    )
  end

  test "admin can view the index" do
    get admin_raw_materials_path
    assert_response :success
    assert_match "Manteca", response.body
  end

  test "admin can view the new form" do
    get new_admin_raw_material_path
    assert_response :success
  end

  test "admin can create a raw material" do
    assert_difference "RawMaterial.count", 1 do
      post admin_raw_materials_path, params: {
        raw_material: {
          name: "Harina 0000", category: "Harinas", brand: "Cañuelas", supplier: "Molinos",
          purchase_price_amount: "25000", purchase_quantity: "25", purchase_unit: "kg", base_unit: "kg", active: "1"
        }
      }
    end

    assert_redirected_to admin_raw_materials_path
    raw_material = RawMaterial.find_by!(name: "Harina 0000")
    assert_equal 2_500_000, raw_material.purchase_price_cents
    assert_equal 100_000, raw_material.unit_cost_cents
  end

  test "creating with incompatible purchase_unit/base_unit re-renders the form with a clear error" do
    assert_no_difference "RawMaterial.count" do
      post admin_raw_materials_path, params: {
        raw_material: {
          name: "Materia Incompatible", purchase_price_amount: "100", purchase_quantity: "1",
          purchase_unit: "kg", base_unit: "l", active: "1"
        }
      }
    end

    assert_response :unprocessable_entity
    assert_match "no es compatible", response.body
  end

  test "admin can view the edit form, including the calculated cost" do
    get edit_admin_raw_material_path(@raw_material)

    assert_response :success
    assert_match "Manteca", response.body
    assert_match "1,000", response.body # costo normalizado actual formateado (format_money usa coma como separador de miles)
  end

  test "admin can update a raw material, and the recalculated cost is shown" do
    patch admin_raw_material_path(@raw_material), params: {
      raw_material: { purchase_price_amount: "1200" }
    }

    assert_redirected_to admin_raw_materials_path
    assert_equal 120_000, @raw_material.reload.unit_cost_cents
  end

  test "updating creates a cost history entry visible on the edit page" do
    patch admin_raw_material_path(@raw_material), params: {
      raw_material: { purchase_price_amount: "1200" }
    }

    get edit_admin_raw_material_path(@raw_material)
    assert_response :success
    assert_match "Historial de costo", response.body
    assert_select "table tbody tr", count: 1
  end

  test "unit_cost_cents cannot be manipulated via params on create" do
    post admin_raw_materials_path, params: {
      raw_material: {
        name: "Materia Manipulada", purchase_price_amount: "1000", purchase_quantity: "1",
        purchase_unit: "kg", base_unit: "kg", active: "1", unit_cost_cents: "999999999"
      }
    }

    raw_material = RawMaterial.find_by!(name: "Materia Manipulada")
    assert_equal 100_000, raw_material.unit_cost_cents
    assert_not_equal 999_999_999, raw_material.unit_cost_cents
  end

  test "unit_cost_cents cannot be manipulated via params on update" do
    patch admin_raw_material_path(@raw_material), params: {
      raw_material: { unit_cost_cents: "999999999" }
    }

    assert_equal 100_000, @raw_material.reload.unit_cost_cents
  end

  test "an invalid update re-renders the edit form with the error and does not change the record" do
    patch admin_raw_material_path(@raw_material), params: {
      raw_material: { purchase_quantity: "0" }
    }

    assert_response :unprocessable_entity
    assert_equal 1, @raw_material.reload.purchase_quantity.to_i
  end
end
