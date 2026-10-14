require "test_helper"
require_relative "../support/visibility_helpers"

# Catálogo y pedidos del cliente mayorista con visibilidad de productos por cliente.
class ProductVisibilityCatalogTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include VisibilityHelpers

  setup { setup_visibility }

  def order_params
    { order: { delivery_date: @delivery.iso8601, payment_method_selected: "cash_on_delivery", customer_comment: "" } }
  end

  # --- catálogo ---

  test "el cliente autorizado ve los productos públicos y los exclusivos suyos" do
    sign_in @user_a
    get dashboard_path

    assert_response :success
    assert_match @rogel.name, response.body
    assert_match @exclusive_a.name, response.body
    assert_match @special_abc.name, response.body
  end

  test "el cliente no autorizado no ve productos exclusivos de otros, pero sí los públicos y los suyos" do
    sign_in @user_b
    get dashboard_path

    assert_match @rogel.name, response.body
    assert_match @special_abc.name, response.body
    assert_no_match @exclusive_a.name, response.body
  end

  test "la búsqueda y el filtro por categoría tampoco filtran productos exclusivos ajenos" do
    sign_in @user_b
    get dashboard_path, params: { q: "exclusivo", category_id: @category.id }

    assert_no_match @exclusive_a.name, response.body
  end

  test "los productos inactivos siguen ocultos aunque el cliente esté autorizado" do
    @exclusive_a.update!(active: false)
    @rogel.update!(active: false)
    sign_in @user_a
    get dashboard_path

    assert_no_match @exclusive_a.name, response.body
    assert_no_match @rogel.name, response.body
    assert_match @special_abc.name, response.body
  end

  test "las reglas de stock existentes se conservan: producto autorizado sin stock y sin vender sin stock sigue bloqueado" do
    StockItem.create!(stock_tracking_started_on: Date.new(2026, 1, 1), stockable: @exclusive_a, active: true, quantity: 1, minimum_quantity: 0)
    @exclusive_a.update!(sell_without_stock: false)

    order = Order.new(customer: @cafe_a, delivery_date: @delivery)
    order.order_items.build(product: @exclusive_a, quantity: 5)

    assert_not order.save
    assert_match(/stock/i, order.errors.full_messages.join)
    assert_no_match(/no está disponible para tu cliente/, order.errors.full_messages.join)
  end

  # --- carrito y pedido ---

  test "agregar al carrito un producto autorizado funciona" do
    sign_in @user_a
    post add_cart_path, params: { product_id: @exclusive_a.id }

    assert_response :redirect
    get cart_path
    assert_match @exclusive_a.name, response.body
  end

  test "agregar al carrito un producto no autorizado (id manipulado) se rechaza" do
    sign_in @user_b
    post add_cart_path, params: { product_id: @exclusive_a.id }

    assert_response :not_found
    get cart_path
    assert_no_match @exclusive_a.name, response.body
  end

  test "cambiar la cantidad de un producto no autorizado no lo agrega al carrito" do
    sign_in @user_b
    patch update_item_cart_path, params: { product_id: @exclusive_a.id, quantity: 5 }
    get cart_path

    assert_no_match @exclusive_a.name, response.body
  end

  test "un cliente autorizado crea el pedido con productos exclusivos" do
    sign_in @user_a
    post add_cart_path, params: { product_id: @rogel.id }
    post add_cart_path, params: { product_id: @exclusive_a.id }

    assert_difference "Order.count", 1 do
      post orders_path, params: order_params
    end
    assert_equal [@rogel.id, @exclusive_a.id].sort, Order.last.order_items.pluck(:product_id).sort
    assert_equal @cafe_a, Order.last.customer
  end

  test "un carrito con un producto que dejó de estar autorizado no crea ningún pedido (ni parcial)" do
    @exclusive_a.update!(authorized_customers: [@cafe_a, @cafe_b])
    sign_in @user_b
    post add_cart_path, params: { product_id: @rogel.id }
    post add_cart_path, params: { product_id: @exclusive_a.id }
    @exclusive_a.update!(authorized_customers: [@cafe_a]) # se revoca con el producto ya en el carrito (sesión)

    assert_no_difference ["Order.count", "OrderItem.count"] do
      post orders_path, params: order_params
    end
    assert_redirected_to cart_path
    follow_redirect!
    assert_match "Este producto no está disponible para tu cliente", response.body
    assert_match @exclusive_a.name, response.body
  end

  test "ir a confirmar con un producto no autorizado en el carrito vuelve al carrito con aviso" do
    @exclusive_a.update!(authorized_customers: [@cafe_a, @cafe_b])
    sign_in @user_b
    post add_cart_path, params: { product_id: @exclusive_a.id }
    @exclusive_a.update!(authorized_customers: [@cafe_a])

    get new_order_path
    assert_redirected_to cart_path
  end

  test "el carrito limpia los productos que dejaron de estar habilitados y avisa" do
    sign_in @user_a
    post add_cart_path, params: { product_id: @exclusive_a.id }
    post add_cart_path, params: { product_id: @rogel.id }
    @exclusive_a.update!(authorized_customers: [@cafe_c])

    get cart_path
    assert_response :success
    assert_match "no está disponible para tu cliente", response.body
    assert_match @rogel.name, response.body
    get cart_path
    assert_no_match(/#{Regexp.escape(@exclusive_a.name)}/, css_select(".cart-items").to_s)
  end

  test "repetir un pedido histórico omite los productos ya no autorizados" do
    order = wholesale_order_for(@cafe_a, [[@rogel, 2], [@exclusive_a, 3]])
    @exclusive_a.update!(authorized_customers: [@cafe_c])
    sign_in @user_a

    post repeat_order_path(order)
    get cart_path

    assert_match @rogel.name, response.body
    assert_no_match(/#{Regexp.escape(@exclusive_a.name)}/, css_select(".cart-items").to_s)
  end

  test "los pedidos históricos siguen visibles con sus productos aunque el producto deje de estar habilitado" do
    order = wholesale_order_for(@cafe_a, [[@exclusive_a, 3]])
    @exclusive_a.update!(authorized_customers: [@cafe_c])
    sign_in @user_a

    get order_path(order)

    assert_response :success
    assert_match @exclusive_a.name, response.body
    get orders_path
    assert_response :success
  end
end
