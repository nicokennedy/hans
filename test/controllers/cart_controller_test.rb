require "test_helper"

class CartControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @category = Category.create!(name: "Alfajores", position: 1, active: true)
    @product = Product.create!(name: "Mini Oreo", category: @category, price_cents: 500_000, cost_cents: 200_000, active: true, position: 1)
    @customer = Customer.create!(name: "Cliente Test", active: true)
    @user = User.create!(email: "cart-customer@example.com", password: "password123", role: "customer", customer: @customer)
    sign_in @user
  end

  test "should get show" do
    get cart_path
    assert_response :success
  end

  test "the quantity control renders an editable number input between the minus and plus buttons" do
    get dashboard_path
    assert_response :success
    assert_select "input.quantity-number-input"
  end

  test "manually typing a quantity updates the cart" do
    patch update_item_cart_path(product_id: @product.id), params: { quantity: "15" }

    get cart_path
    assert_select "input.quantity-number-input[value=?]", "15"
  end

  test "quantities greater than 9 (two or three digits) are stored correctly, not truncated" do
    patch update_item_cart_path(product_id: @product.id), params: { quantity: "24" }

    get cart_path
    assert_select "input.quantity-number-input[value=?]", "24"
  end

  test "setting quantity to 0 removes the product from the cart" do
    patch update_item_cart_path(product_id: @product.id), params: { quantity: "5" }
    patch update_item_cart_path(product_id: @product.id), params: { quantity: "0" }

    get cart_path
    assert_match "carrito está vacío", response.body
  end

  test "the server rejects a negative quantity, leaving the cart unchanged" do
    patch update_item_cart_path(product_id: @product.id), params: { quantity: "5" }
    patch update_item_cart_path(product_id: @product.id), params: { quantity: "-3" }

    get cart_path
    assert_select "input.quantity-number-input[value=?]", "5"
  end

  test "the server rejects a decimal quantity, leaving the cart unchanged" do
    patch update_item_cart_path(product_id: @product.id), params: { quantity: "5" }
    patch update_item_cart_path(product_id: @product.id), params: { quantity: "2.5" }

    get cart_path
    assert_select "input.quantity-number-input[value=?]", "5"
  end

  test "the server rejects a non-numeric quantity, leaving the cart unchanged" do
    patch update_item_cart_path(product_id: @product.id), params: { quantity: "5" }
    patch update_item_cart_path(product_id: @product.id), params: { quantity: "abc" }

    get cart_path
    assert_select "input.quantity-number-input[value=?]", "5"
  end

  test "the minus and plus buttons still work alongside the manual input" do
    patch update_item_cart_path(product_id: @product.id), params: { quantity: "5" }
    post add_cart_path(product_id: @product.id)

    get cart_path
    assert_select "input.quantity-number-input[value=?]", "6"

    patch update_item_cart_path(product_id: @product.id), params: { quantity: "3" }
    get cart_path
    assert_select "input.quantity-number-input[value=?]", "3"
  end

  test "the minus button never goes below 0" do
    patch update_item_cart_path(product_id: @product.id), params: { quantity: "0" }

    get cart_path
    assert_match "carrito está vacío", response.body
  end
end
