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

  private

  def create_product(name, category, price, cost, active, position)
    Product.create!(name: name, category: category, price_cents: price, cost_cents: cost, active: active, position: position)
  end

  def assert_product_names(*expected)
    actual = css_select("tbody tr td.fw-bold").map { |cell| cell.text.strip }
    assert_equal expected, actual
  end
end