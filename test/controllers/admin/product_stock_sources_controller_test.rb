require "test_helper"

class Admin::ProductStockSourcesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = User.create!(email: "pss-admin-#{rand(1_000_000)}@example.com", password: "password123", role: "admin")
    @production = User.create!(email: "pss-production-#{rand(1_000_000)}@example.com", password: "password123", role: "production")
    customer = Customer.create!(name: "PSS Cliente #{rand(1_000_000)}", active: true)
    @customer_user = User.create!(email: "pss-customer-#{rand(1_000_000)}@example.com", password: "password123", role: "customer", customer: customer)

    category = Category.create!(name: "PSSCtrlCat#{rand(1_000_000)}", position: 1, active: true)
    @product = Product.create!(name: "Alfajor PSSCtrl", category: category, price_cents: 500, cost_cents: 200, active: true, position: 1)
    @tapas = Preparation.create!(name: "Tapas PSSCtrl", yield_quantity: 1, yield_unit: "un", stock_only: true)
    @masa = Preparation.create!(name: "Masa PSSCtrl", yield_quantity: 1, yield_unit: "kg")
  end

  test "admin links a product to a stock-only object" do
    sign_in @admin

    assert_difference "ProductStockSource.count", 1 do
      post admin_product_stock_sources_path(@product), params: { product_stock_source: { preparation_id: @tapas.id, quantity: "1" } }
    end

    assert_redirected_to edit_admin_product_path(@product)
    assert_equal BigDecimal(1), @product.product_stock_sources.first.quantity
  end

  test "linking a normal recipe preparation is rejected" do
    sign_in @admin

    assert_no_difference "ProductStockSource.count" do
      post admin_product_stock_sources_path(@product), params: { product_stock_source: { preparation_id: @masa.id, quantity: "1" } }
    end

    assert_redirected_to edit_admin_product_path(@product)
    follow_redirect!
    assert_match "objeto de stock", response.body
  end

  test "admin unlinks it" do
    source = ProductStockSource.create!(product: @product, preparation: @tapas)
    sign_in @admin

    assert_difference "ProductStockSource.count", -1 do
      delete admin_product_stock_source_path(@product, source)
    end
    assert_redirected_to edit_admin_product_path(@product)
  end

  test "the product edit page lists current links and offers the remaining stock objects" do
    other = Preparation.create!(name: "Otras Tapas PSSCtrl", yield_quantity: 1, yield_unit: "un", stock_only: true)
    ProductStockSource.create!(product: @product, preparation: @tapas)
    sign_in @admin

    get edit_admin_product_path(@product)

    assert_select "#product-stock-sources", text: /Tapas PSSCtrl/
    assert_select "#product-stock-sources select option", text: other.name
    assert_select "#product-stock-sources select option", text: @tapas.name, count: 0 # ya vinculada
    assert_select "#product-stock-sources select option", text: @masa.name, count: 0 # no es objeto de stock
  end

  test "the stock history page lists the products that deduct from a pool" do
    ProductStockSource.create!(product: @product, preparation: @tapas)
    item = StockItem.create!(stockable: @tapas, active: true, quantity: 10, minimum_quantity: 5)
    sign_in @admin

    get admin_stock_item_path(item)

    assert_select "h2", text: "Productos que descuentan de este stock"
    assert_match "Alfajor PSSCtrl", response.body
  end

  test "production and customer cannot change the links" do
    [ @production, @customer_user ].each do |user|
      sign_in user

      assert_no_difference "ProductStockSource.count" do
        post admin_product_stock_sources_path(@product), params: { product_stock_source: { preparation_id: @tapas.id, quantity: "1" } }
      end
    end
  end
end
