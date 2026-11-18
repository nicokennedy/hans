require "test_helper"

# R0 de Repartos: el rol repartidor entra solo a /reparto, nunca a /admin ni al portal de
# clientes, y su sesión queda recordada en el celular corporativo (decisión D7).
class Reparto::DriverAccessTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  REMEMBER_COOKIE = "remember_user_token".freeze

  setup do
    @driver = User.create!(email: "reparto-driver@example.com", password: "password123", role: "driver")
    @admin = User.create!(email: "reparto-admin@example.com", password: "password123", role: "admin")
    @production = User.create!(email: "reparto-production@example.com", password: "password123", role: "production")
    @customer = Customer.create!(name: "Cliente RepartoTest", active: true)
    @customer_user = User.create!(email: "reparto-customer@example.com", password: "password123", role: "customer", customer: @customer)
  end

  # --- Login y pantalla inicial ---

  test "the driver logs in and lands on the delivery portal" do
    post user_session_path, params: { user: { email: @driver.email, password: "password123" } }
    assert_redirected_to reparto_root_path
    follow_redirect!
    assert_response :success
    assert_match "Hoy no tenés reparto", response.body
    assert_no_match(/translation missing/i, response.body)
  end

  test "the driver is not signed out for lacking a customer" do
    sign_in @driver
    get reparto_root_path
    assert_response :success
  end

  test "the home page icon sends a signed-in driver to the delivery portal" do
    sign_in @driver
    get root_path
    assert_redirected_to reparto_root_path
  end

  test "the customer dashboard sends the driver to the delivery portal" do
    sign_in @driver
    get dashboard_path
    assert_redirected_to reparto_root_path
  end

  test "the driver can open the prototype" do
    sign_in @driver
    get reparto_prototype_path
    assert_response :success
    assert_match "Reparto HANS", response.body
    assert_match "STOPS", response.body
  end

  # --- Lo que el repartidor NO puede abrir ---

  test "the driver cannot open any admin screen" do
    sign_in @driver
    [admin_root_path, admin_orders_path, admin_customers_path, admin_production_index_path,
     admin_administration_root_path, admin_retail_orders_path, admin_stock_path,
     admin_push_settings_path, admin_delivery_routes_prototype_path].each do |path|
      get path
      assert_redirected_to reparto_root_path, "#{path} no debería abrirse para el repartidor"
    end
  end

  test "the driver cannot use the customer cart or orders" do
    sign_in @driver
    [cart_path, orders_path, new_order_path].each do |path|
      get path
      assert_redirected_to reparto_root_path, "#{path} no debería abrirse para el repartidor"
    end
  end

  test "the driver cannot register a payment on an order" do
    category = Category.create!(name: "Cat RepartoTest", position: 1, active: true)
    product = Product.create!(name: "Prod RepartoTest", category: category, internal_category: "X", price_cents: 1000, cost_cents: 100, active: true, position: 1)
    order = Order.new(customer: @customer, delivery_date: next_delivery_date)
    order.order_items.build(product: product, quantity: 1)
    order.save!

    sign_in @driver
    assert_no_difference -> { Payment.count } do
      post admin_order_payments_path(order), params: { payment: { amount: "10", paid_at: Date.current, payment_method: "cash_on_delivery" } }
    end
    assert_redirected_to reparto_root_path
  end

  # --- Otros roles en /reparto ---

  test "admin can preview the delivery portal and both prototypes" do
    sign_in @admin
    get reparto_root_path
    assert_response :success
    get reparto_prototype_path
    assert_response :success
    get admin_delivery_routes_prototype_path
    assert_response :success
  end

  test "production and customers cannot open the delivery portal" do
    sign_in @production
    get reparto_root_path
    assert_redirected_to admin_production_index_path

    sign_in @customer_user
    get reparto_prototype_path
    assert_redirected_to dashboard_path
  end

  test "the delivery portal requires signing in" do
    get reparto_root_path
    assert_redirected_to new_user_session_path
  end

  # --- Sesión recordada en el celular (D7) ---

  test "the driver stays signed in after the browser session is lost" do
    remember_cookie = log_in_and_take_remember_cookie(@driver)
    assert remember_cookie.present?, "el repartidor debería quedar recordado"

    reset!
    cookies[REMEMBER_COOKIE] = remember_cookie
    get reparto_root_path
    assert_response :success
  end

  test "other roles are not remembered" do
    [@admin, @customer_user].each do |user|
      assert_nil log_in_and_take_remember_cookie(user), "#{user.role} no debería quedar recordado"
      reset!
    end
  end

  test "the remembered session expires after 60 days without use" do
    remember_cookie = log_in_and_take_remember_cookie(@driver)

    travel 61.days do
      reset!
      cookies[REMEMBER_COOKIE] = remember_cookie
      get reparto_root_path
      assert_redirected_to new_user_session_path
    end
  end

  test "using the phone renews the remembered session" do
    remember_cookie = log_in_and_take_remember_cookie(@driver)

    travel 40.days
    reset!
    cookies[REMEMBER_COOKIE] = remember_cookie
    get reparto_root_path
    assert_response :success
    renewed_cookie = cookies[REMEMBER_COOKIE]

    travel 40.days
    reset!
    cookies[REMEMBER_COOKIE] = renewed_cookie
    get reparto_root_path
    assert_response :success
  ensure
    travel_back
  end

  test "changing the driver password revokes the remembered session" do
    remember_cookie = log_in_and_take_remember_cookie(@driver)
    @driver.update!(password: "otra-clave-segura-123")

    reset!
    cookies[REMEMBER_COOKIE] = remember_cookie
    get reparto_root_path
    assert_redirected_to new_user_session_path
  end

  test "signing out revokes the remembered session" do
    remember_cookie = log_in_and_take_remember_cookie(@driver)
    delete destroy_user_session_path

    reset!
    cookies[REMEMBER_COOKIE] = remember_cookie
    get reparto_root_path
    assert_redirected_to new_user_session_path
  end

  private

  def log_in_and_take_remember_cookie(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
    cookies[REMEMBER_COOKIE].presence
  end
end
