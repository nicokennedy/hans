require "test_helper"

class Admin::StockItemsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = User.create!(email: "stockitemsctrl-admin-#{rand(1_000_000)}@example.com", password: "password123", role: "admin")
    @production_user = User.create!(email: "stockitemsctrl-production-#{rand(1_000_000)}@example.com", password: "password123", role: "production")
    customer = Customer.create!(name: "StockItemsCtrlCustomer#{rand(1_000_000)}", active: true)
    @customer_user = User.create!(email: "stockitemsctrl-customer-#{rand(1_000_000)}@example.com", password: "password123", role: "customer", customer: customer)

    @raw = RawMaterial.create!(name: "RM StockItemsCtrl #{rand(1_000_000)}", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    @preparation = Preparation.create!(name: "Prep StockItemsCtrl #{rand(1_000_000)}", yield_quantity: 1, yield_unit: "kg")
    @preparation.recipe_components.create!(component: @raw, quantity: 1, unit: "kg")
    @stock_item = StockItem.create!(stockable: @preparation, active: true, quantity: 5, minimum_quantity: 2)
  end

  # --- show ---

  test "admin can view a stock item's history" do
    sign_in @admin
    get admin_stock_item_path(@stock_item)
    assert_response :success
    assert_match @stock_item.name, response.body
  end

  test "production can view a stock item's history" do
    sign_in @production_user
    get admin_stock_item_path(@stock_item)
    assert_response :success
  end

  test "customer is blocked from a stock item's history, even via direct URL" do
    sign_in @customer_user
    get admin_stock_item_path(@stock_item)
    assert_redirected_to dashboard_path
  end

  # --- create (admin only — enabling stock control) ---

  test "admin can enable stock control for a Preparation that doesn't have it yet" do
    other_preparation = Preparation.create!(name: "Other Prep StockItemsCtrl #{rand(1_000_000)}", yield_quantity: 1, yield_unit: "kg")
    other_preparation.recipe_components.create!(component: @raw, quantity: 1, unit: "kg")

    sign_in @admin
    assert_difference "StockItem.count", 1 do
      post admin_stock_items_path, params: { stock_item: { stockable_type: "Preparation", stockable_id: other_preparation.id, active: "1", minimum_quantity: 3 } }
    end

    assert_redirected_to edit_admin_preparation_path(other_preparation)
    assert other_preparation.reload.stock_item.active?
  end

  test "production cannot enable stock control (create is admin-only)" do
    other_preparation = Preparation.create!(name: "Other Prep StockItemsCtrl2 #{rand(1_000_000)}", yield_quantity: 1, yield_unit: "kg")
    other_preparation.recipe_components.create!(component: @raw, quantity: 1, unit: "kg")

    sign_in @production_user
    assert_no_difference "StockItem.count" do
      post admin_stock_items_path, params: { stock_item: { stockable_type: "Preparation", stockable_id: other_preparation.id, active: "1", minimum_quantity: 3 } }
    end
  end

  test "customer cannot enable stock control, even via direct URL/param manipulation" do
    other_preparation = Preparation.create!(name: "Other Prep StockItemsCtrl3 #{rand(1_000_000)}", yield_quantity: 1, yield_unit: "kg")
    other_preparation.recipe_components.create!(component: @raw, quantity: 1, unit: "kg")

    sign_in @customer_user
    assert_no_difference "StockItem.count" do
      post admin_stock_items_path, params: { stock_item: { stockable_type: "Preparation", stockable_id: other_preparation.id, active: "1", minimum_quantity: 3 } }
    end
    assert_redirected_to dashboard_path
  end

  test "create rejects a stockable_type outside the allowed list" do
    sign_in @admin
    assert_no_difference "StockItem.count" do
      post admin_stock_items_path, params: { stock_item: { stockable_type: "User", stockable_id: @admin.id, active: "1", minimum_quantity: 3 } }
    end
    assert_redirected_to admin_root_path
  end

  # --- update (admin only — editing minimum/active) ---

  test "admin can update a stock item's minimum and active flag" do
    sign_in @admin
    patch admin_stock_item_path(@stock_item), params: { stock_item: { minimum_quantity: 8, active: "0" } }

    assert_redirected_to edit_admin_preparation_path(@preparation)
    @stock_item.reload
    assert_equal BigDecimal("8"), @stock_item.minimum_quantity
    assert_not @stock_item.active?
  end

  test "production cannot update a stock item's configuration" do
    sign_in @production_user
    patch admin_stock_item_path(@stock_item), params: { stock_item: { minimum_quantity: 8 } }

    assert_equal BigDecimal("2"), @stock_item.reload.minimum_quantity
  end

  test "customer cannot update a stock item's configuration, even via direct URL/param manipulation" do
    sign_in @customer_user
    patch admin_stock_item_path(@stock_item), params: { stock_item: { minimum_quantity: 8 } }

    assert_redirected_to dashboard_path
    assert_equal BigDecimal("2"), @stock_item.reload.minimum_quantity
  end

  # --- register_production (admin_or_production) ---

  test "admin can register production" do
    sign_in @admin
    post register_production_admin_stock_item_path(@stock_item), params: { quantity: 2 }

    assert_redirected_to admin_stock_path
    assert_equal BigDecimal("7"), @stock_item.reload.quantity
  end

  test "production can register production" do
    sign_in @production_user
    post register_production_admin_stock_item_path(@stock_item), params: { quantity: 2 }

    assert_redirected_to admin_stock_path
    assert_equal BigDecimal("7"), @stock_item.reload.quantity
  end

  test "customer cannot register production, even via direct URL/param manipulation" do
    sign_in @customer_user
    post register_production_admin_stock_item_path(@stock_item), params: { quantity: 2 }

    assert_redirected_to dashboard_path
    assert_equal BigDecimal("5"), @stock_item.reload.quantity
  end

  test "registering an invalid quantity redirects back with an alert and makes no change" do
    sign_in @admin
    post register_production_admin_stock_item_path(@stock_item), params: { quantity: 0 }

    assert_redirected_to admin_stock_path
    assert_equal BigDecimal("5"), @stock_item.reload.quantity
  end

  # --- register_count (admin_or_production) ---

  test "admin can register a stock count" do
    sign_in @admin
    post register_count_admin_stock_item_path(@stock_item), params: { counted_quantity: 3 }

    assert_redirected_to admin_stock_path
    assert_equal BigDecimal("3"), @stock_item.reload.quantity
  end

  test "production can register a stock count" do
    sign_in @production_user
    post register_count_admin_stock_item_path(@stock_item), params: { counted_quantity: 3 }

    assert_redirected_to admin_stock_path
    assert_equal BigDecimal("3"), @stock_item.reload.quantity
  end

  test "customer cannot register a stock count, even via direct URL/param manipulation" do
    sign_in @customer_user
    post register_count_admin_stock_item_path(@stock_item), params: { counted_quantity: 3 }

    assert_redirected_to dashboard_path
    assert_equal BigDecimal("5"), @stock_item.reload.quantity
  end

  test "registering a negative count redirects back with an alert and makes no change" do
    sign_in @admin
    post register_count_admin_stock_item_path(@stock_item), params: { counted_quantity: -1 }

    assert_redirected_to admin_stock_path
    assert_equal BigDecimal("5"), @stock_item.reload.quantity
  end
end
