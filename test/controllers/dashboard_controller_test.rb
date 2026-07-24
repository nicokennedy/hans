require "test_helper"

class DashboardControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @category = Category.create!(name: "Fríos", position: 1, active: true)
    @customer = Customer.create!(name: "Café Test", active: true)
    @user = User.create!(email: "dashboard-customer@example.com", password: "password123", role: "customer", customer: @customer)
  end

  test "should get show" do
    sign_in @user
    get dashboard_path
    assert_response :success
  end

  test "regression: an active product in a category outside the old hardcoded whitelist still appears in the catalog" do
    product = Product.create!(
      name: "Mini chocotorta",
      category: @category, # "Fríos" — not one of the categories the view used to hardcode
      price_cents: 470_000,
      cost_cents: 299_600,
      active: true,
      position: 1
    )

    sign_in @user
    get dashboard_path

    assert_response :success
    assert_match product.name, response.body
  end

  test "the product appears when searching for 'chocotorta'" do
    product = Product.create!(name: "Mini chocotorta", category: @category, price_cents: 470_000, cost_cents: 299_600, active: true, position: 1)

    sign_in @user
    get dashboard_path, params: { q: "chocotorta" }

    assert_response :success
    assert_match product.name, response.body
  end

  test "an inactive product does not appear in the catalog" do
    Product.create!(name: "Producto Inactivo Test", category: @category, price_cents: 100_000, cost_cents: 50_000, active: false, position: 1)

    sign_in @user
    get dashboard_path

    assert_response :success
    assert_no_match "Producto Inactivo Test", response.body
  end

  test "the catalog never exposes cost_cents or cost figures, only price" do
    Product.create!(name: "Mini chocotorta", category: @category, price_cents: 470_000, cost_cents: 299_600, active: true, position: 1)

    sign_in @user
    get dashboard_path

    assert_response :success
    assert_no_match "2,996", response.body # cost in pesos must never render
    assert_match "4,700", response.body # price in pesos is expected to render
  end

  test "the catalog is the same shared list for every customer, without leaking data between sessions" do
    product = Product.create!(name: "Mini chocotorta", category: @category, price_cents: 470_000, cost_cents: 299_600, active: true, position: 1)

    other_customer = Customer.create!(name: "Otro Café", active: true)
    other_user = User.create!(email: "dashboard-other@example.com", password: "password123", role: "customer", customer: other_customer)

    sign_in @user
    get dashboard_path
    assert_match product.name, response.body
    assert_match @customer.name, response.body

    sign_out @user
    sign_in other_user
    get dashboard_path
    assert_match product.name, response.body
    assert_match other_customer.name, response.body
    assert_no_match @customer.name, response.body
  end
end
