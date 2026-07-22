require "test_helper"

class Admin::ProductsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = User.create!(email: "products-admin@example.com", password: "password123", role: "admin")
    sign_in @admin
    Product.delete_all
    Category.delete_all
    @alfajores = Category.create!(name: "Alfajores", position: 1, active: true)
    @tortas = Category.create!(name: "Tortas", position: 2, active: true)
    @clasico = create_product("Alfajor Clásico", @alfajores, 300, 100, true, 2)
    @blanco = create_product("alfajor Blanco", @alfajores, 200, 150, false, 1)
    @torta = create_product("Torta Brownie", @tortas, 900, 500, true, 1)
  end

  test "searches partially by name" do
    get admin_products_path, params: { q: "Brown" }
    assert_response :success
    assert_product_names "Torta Brownie"
  end

  test "searches names case insensitively" do
    get admin_products_path, params: { q: "ALFAJOR" }
    assert_response :success
    assert_product_names "alfajor Blanco", "Alfajor Clásico"
  end

  test "filters by category" do
    get admin_products_path, params: { category_id: @tortas.id }
    assert_response :success
    assert_product_names "Torta Brownie"
  end

  test "filters by status" do
    get admin_products_path, params: { status: "inactive" }
    assert_response :success
    assert_product_names "alfajor Blanco"
  end

  test "sorts every allowed field in both directions" do
    expectations = {
      name: { asc: ["Alfajor Clásico", "Torta Brownie", "alfajor Blanco"], desc: ["alfajor Blanco", "Torta Brownie", "Alfajor Clásico"] },
      category: { asc: ["Alfajor Clásico", "alfajor Blanco", "Torta Brownie"], desc: ["Torta Brownie", "Alfajor Clásico", "alfajor Blanco"] },
      price: { asc: ["alfajor Blanco", "Alfajor Clásico", "Torta Brownie"], desc: ["Torta Brownie", "Alfajor Clásico", "alfajor Blanco"] },
      cost: { asc: ["Alfajor Clásico", "alfajor Blanco", "Torta Brownie"], desc: ["Torta Brownie", "alfajor Blanco", "Alfajor Clásico"] }
    }
    expectations.each do |sort, directions|
      directions.each do |direction, expected|
        get admin_products_path, params: { sort: sort, direction: direction }
        assert_response :success
        assert_product_names(*expected)
      end
    end
  end

  test "combines search filter and sorting" do
    get admin_products_path, params: { q: "alfajor", category_id: @alfajores.id, status: "active", sort: "price", direction: "desc" }
    assert_response :success
    assert_product_names "Alfajor Clásico"
  end

  test "falls back safely for invalid sort parameters" do
    get admin_products_path, params: { sort: "name; DROP TABLE products", direction: "sideways" }
    assert_response :success
    assert_product_names "alfajor Blanco", "Alfajor Clásico", "Torta Brownie"
    assert_equal 3, Product.count
  end

  test "the full edit form includes a Categoría interna field" do
    get edit_admin_product_path(@clasico)
    assert_response :success
    assert_select "label", text: "Categoría interna"
    assert_select "input#product_internal_category"
  end

  test "updates internal_category through the full edit form, independently from category" do
    patch admin_product_path(@clasico), params: { product: { internal_category: "AL" } }

    assert_redirected_to admin_products_path
    @clasico.reload
    assert_equal "AL", @clasico.internal_category
    assert_equal @alfajores.id, @clasico.category_id
  end

  test "inline update succeeds for an allowed field and re-renders just that value" do
    patch update_inline_admin_product_path(@clasico, field: "price_amount"), params: { product: { price_amount: "350" } }

    assert_response :success
    assert_equal 35_000, @clasico.reload.price_cents
    assert_match "35.000", @response.body
  end

  test "inline update edits internal_category independently from category_id" do
    patch update_inline_admin_product_path(@clasico, field: "internal_category"), params: { product: { internal_category: "CO" } }

    assert_response :success
    @clasico.reload
    assert_equal "CO", @clasico.internal_category
    assert_equal @alfajores.id, @clasico.category_id
  end

  test "inline update edits category_id independently from internal_category" do
    @clasico.update!(internal_category: "AL")

    patch update_inline_admin_product_path(@clasico, field: "category_id"), params: { product: { category_id: @tortas.id } }

    assert_response :success
    @clasico.reload
    assert_equal @tortas.id, @clasico.category_id
    assert_equal "AL", @clasico.internal_category
  end

  test "rejects an inline update PATCH for a field outside the whitelist" do
    patch update_inline_admin_product_path(@clasico, field: "active"), params: { product: { active: false } }

    assert_response :not_found
    assert @clasico.reload.active?
  end

  test "rejects an inline edit GET for a field outside the whitelist" do
    get edit_inline_admin_product_path(@clasico, field: "position")

    assert_response :not_found
  end

  test "an inline validation error re-renders with an error and keeps the entered value without saving" do
    original_name = @clasico.name

    patch update_inline_admin_product_path(@clasico, field: "name"), params: { product: { name: "" } }

    assert_response :unprocessable_entity
    assert_equal original_name, @clasico.reload.name
    assert_select ".text-danger"
    assert_select "input[value='']"
  end

  test "an inline update to one field leaves the rest of the product unchanged" do
    original_price = @clasico.price_cents
    original_category_id = @clasico.category_id
    original_active = @clasico.active

    patch update_inline_admin_product_path(@clasico, field: "cost_amount"), params: { product: { cost_amount: "150" } }

    @clasico.reload
    assert_equal 15_000, @clasico.cost_cents
    assert_equal original_price, @clasico.price_cents
    assert_equal original_category_id, @clasico.category_id
    assert_equal original_active, @clasico.active
  end

  private

  def create_product(name, category, price, cost, active, position)
    Product.create!(name: name, category: category, price_cents: price, cost_cents: cost, active: active, position: position)
  end

  def assert_product_names(*expected)
    actual = css_select("tbody tr td.fw-bold span").map { |cell| cell.text.strip }
    assert_equal expected, actual
  end
end