require "test_helper"

class Admin::StockControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = User.create!(email: "stockctrl-admin-#{rand(1_000_000)}@example.com", password: "password123", role: "admin")
    @production_user = User.create!(email: "stockctrl-production-#{rand(1_000_000)}@example.com", password: "password123", role: "production")
    customer = Customer.create!(name: "StockCtrlCustomer#{rand(1_000_000)}", active: true)
    @customer_user = User.create!(email: "stockctrl-customer-#{rand(1_000_000)}@example.com", password: "password123", role: "customer", customer: customer)

    raw = RawMaterial.create!(name: "RM StockCtrl #{rand(1_000_000)}", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    preparation = Preparation.create!(name: "Prep StockCtrl #{rand(1_000_000)}", yield_quantity: 1, yield_unit: "kg")
    preparation.recipe_components.create!(component: raw, quantity: 1, unit: "kg")
    @stock_item = StockItem.create!(stock_tracking_started_on: Date.new(2026, 1, 1), stockable: preparation, active: true, quantity: 3, minimum_quantity: 10)
  end

  test "admin can view the dashboard" do
    sign_in @admin
    get admin_stock_path
    assert_response :success
    assert_match @stock_item.name, response.body
  end

  test "production can view the dashboard" do
    sign_in @production_user
    get admin_stock_path
    assert_response :success
  end

  test "customer is blocked from the dashboard, even via direct URL" do
    sign_in @customer_user
    get admin_stock_path
    assert_redirected_to dashboard_path
  end

  test "a signed-out visitor is redirected to sign in" do
    get admin_stock_path
    assert_redirected_to new_user_session_path
  end

  test "the dashboard shows items needing production above the minimum threshold" do
    sign_in @admin
    get admin_stock_path
    assert_response :success
    assert_match "PRODUCIR", response.body
  end
end
