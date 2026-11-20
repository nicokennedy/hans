require "test_helper"
require_relative "../../support/delivery_route_helpers"

class Admin::DeliveryRoutesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include DeliveryRouteHelpers

  setup do
    setup_delivery_data
    @aurora = create_customer("Café Aurora", address: "Av. Colón 2345", address_unit: "Local 3")
    @sin_dir = create_customer("Bistró Verde")
    @o1 = create_order(@aurora)
    @o2 = create_order(@sin_dir)
    @canceled = create_order(@aurora, status: "canceled")
  end

  def create_route_via_ui(ids = [@o1.id, @o2.id])
    post admin_delivery_routes_path, params: { date: @date.iso8601, order_ids: ids, driver_id: @driver.id }
    DeliveryRoute.find_by!(date: @date, driver: @driver)
  end

  test "the index lists the day's orders with address, amounts and missing-address warnings" do
    sign_in @admin
    get admin_delivery_routes_path(date: @date.iso8601)
    assert_response :success
    assert_match "Café Aurora", response.body
    assert_match "Av. Colón 2345 · Local 3", response.body
    assert_match "Sin dirección cargada", response.body
    assert_match @o1.number, response.body
    assert_no_match @canceled.number, response.body
    assert_select "a[href=?]", admin_delivery_routes_demo_path, text: "Modo demostración"
  end

  test "admin creates a route and edits it from the screens" do
    sign_in @admin
    route = create_route_via_ui
    assert_redirected_to admin_delivery_route_path(route)
    follow_redirect!
    assert_response :success
    assert_match "Chiara · Reparto 1", response.body

    stop = route.active_stops.last
    patch move_admin_delivery_route_stop_path(route, stop), params: { direction: "up" }
    assert_equal 1, stop.reload.position

    post admin_delivery_route_stops_path(route), params: { stop: { kind: "purchase", title: "Comprar cajas", address: "Rivadavia 100", notes: "Pedir factura" } }
    manual = route.active_stops.last
    assert_equal "Comprar cajas", manual.title

    patch admin_delivery_route_stop_path(route, manual), params: { stop: { title: "Comprar cajas grandes", address: "Rivadavia 100" } }
    assert_equal "Comprar cajas grandes", manual.reload.title

    patch remove_admin_delivery_route_stop_path(route, stop), params: { removal_kind: "owners_deliver" }
    assert stop.reload.removed?
    follow_redirect!
    assert_match "Fuera del recorrido · 1", response.body

    patch restore_admin_delivery_route_stop_path(route, stop)
    assert_not stop.reload.removed?
  end

  test "adding an order twice shows an error and does not duplicate" do
    sign_in @admin
    route = create_route_via_ui([@o1.id])
    assert_no_difference -> { DeliveryStop.count } do
      post add_orders_admin_delivery_route_stops_path(route), params: { order_ids: [@o1.id] }
    end
    assert_match "ya está en este recorrido", flash[:alert]

    post add_orders_admin_delivery_route_stops_path(route), params: { order_ids: [@o2.id] }
    assert_equal 2, route.active_stops.count
  end

  test "a canceled order cannot be forced into a route" do
    sign_in @admin
    route = create_route_via_ui([@o1.id])
    post add_orders_admin_delivery_route_stops_path(route), params: { order_ids: [@canceled.id] }
    assert_equal 1, route.active_stops.count
    assert flash[:alert].present?
  end

  test "the driver-format preview, stop detail and route sheet render" do
    sign_in @admin
    route = create_route_via_ui
    get preview_admin_delivery_route_path(route)
    assert_response :success
    assert_match "VISTA PREVIA", response.body
    assert_match "Sin dirección cargada", response.body

    stop = route.active_stops.find_by(order: @o1)
    get preview_admin_delivery_route_path(route, stop_id: stop.id)
    assert_response :success
    assert_match "LLEVÁS", response.body
    assert_match "CÓMO LLEGAR", response.body

    get sheet_admin_delivery_route_path(route)
    assert_response :success
    assert_match "Hoja de ruta", response.body
    assert_match "SIN DIRECCIÓN", response.body
  end

  test "only admins can see or change routes" do
    sign_in @admin
    route = create_route_via_ui([@o1.id])
    stop = route.active_stops.first

    driver = User.create!(email: "rt-driver@example.com", password: "password123", role: "driver")
    production = User.create!(email: "rt-prod@example.com", password: "password123", role: "production")
    customer_user = User.create!(email: "rt-customer@example.com", password: "password123", role: "customer", customer: @aurora)

    { driver => reparto_root_path, production => admin_production_index_path, customer_user => dashboard_path }.each do |user, fallback|
      sign_in user
      [-> { get admin_delivery_routes_path }, -> { get admin_delivery_route_path(route) }, -> { get preview_admin_delivery_route_path(route) },
       -> { post admin_delivery_routes_path, params: { date: (@date + 1).iso8601 } },
       -> { post admin_delivery_route_stops_path(route), params: { stop: { kind: "errand", title: "x" } } },
       -> { patch move_admin_delivery_route_stop_path(route, stop), params: { direction: "down" } },
       -> { patch remove_admin_delivery_route_stop_path(route, stop), params: { removal_kind: "owners_deliver" } }].each do |request|
        request.call
        assert_redirected_to fallback
      end
    end

    assert_equal 1, DeliveryRoute.count
    assert_not stop.reload.removed?
    assert_equal 1, route.active_stops.count
  end

  test "the screens never change orders, payments or stock" do
    sign_in @admin
    snapshot = -> { [Order.order(:id).pluck(:status, :payment_status, :amount_paid_cents, :updated_at), Payment.count, CustomerPayment.count, StockMovement.count, Expense.count] }
    before = snapshot.call

    route = create_route_via_ui
    patch move_admin_delivery_route_stop_path(route, route.active_stops.last), params: { direction: "up" }
    patch remove_admin_delivery_route_stop_path(route, route.active_stops.first), params: { removal_kind: "rescheduled" }
    get preview_admin_delivery_route_path(route)

    assert_equal before, snapshot.call
  end

  test "the demo stays separate from the real module" do
    sign_in @admin
    get admin_delivery_routes_demo_path
    assert_response :success
    assert_match "MODO DEMOSTRACIÓN", response.body
    get admin_delivery_routes_path
    assert_no_match "MODO DEMOSTRACIÓN", response.body
  end

  test "two drivers share a date: create both routes and pass an order from one to the other" do
    emilio = create_driver("Emilio")
    sign_in @admin
    post admin_delivery_routes_path, params: { date: @date.iso8601, order_ids: [@o1.id], driver_id: @driver.id }
    post admin_delivery_routes_path, params: { date: @date.iso8601, order_ids: [@o2.id], driver_id: emilio.id }
    chiara_route = DeliveryRoute.find_by!(date: @date, driver: @driver)
    emilio_route = DeliveryRoute.find_by!(date: @date, driver: emilio)

    get admin_delivery_routes_path(date: @date.iso8601)
    assert_match "Chiara", response.body
    assert_match "Emilio", response.body
    assert_match "Pedidos sin asignar · 0", response.body

    stop = chiara_route.active_stops.first
    patch transfer_admin_delivery_route_stop_path(chiara_route, stop), params: { target_route_id: emilio_route.id }
    assert_equal [@o2.id, @o1.id], emilio_route.active_stops.map(&:order_id)
    assert_equal 0, chiara_route.active_stops.count
    follow_redirect!
    assert_match "Pasó a otro reparto", response.body
  end

  test "creating a route without a driver or with an inactive one is refused" do
    sign_in @admin
    assert_no_difference -> { DeliveryRoute.count } do
      post admin_delivery_routes_path, params: { date: @date.iso8601, order_ids: [@o1.id] }
      post admin_delivery_routes_path, params: { date: @date.iso8601, order_ids: [@o1.id], driver_id: create_driver("Baja", active: false).id }
    end
  end

  test "a second route for the same driver and day from the screen, without duplicates" do
    sign_in @admin
    first = create_route_via_ui([@o1.id])

    get admin_delivery_routes_path(date: @date.iso8601)
    assert_select "a[href='#nuevo-reparto']", text: "+ Crear nuevo reparto"
    assert_select "#new-route-driver option[value='#{@driver.id}']", text: /Chiara \(ya tiene 1 reparto este día\)/
    assert_select "input[type=checkbox][value='#{@o1.id}']", 0
    assert_select "input[type=checkbox][value='#{@o2.id}']", 1
    token = css_select("input[name=creation_token]").first["value"]
    assert token.present?

    params = { date: @date.iso8601, order_ids: [@o2.id], driver_id: @driver.id, creation_token: token }
    assert_difference -> { DeliveryRoute.count }, 1 do
      post admin_delivery_routes_path, params: params
      post admin_delivery_routes_path, params: params
    end
    second = DeliveryRoute.where(date: @date, driver: @driver).where.not(id: first.id).sole
    assert_redirected_to admin_delivery_route_path(second)
    assert_match "ya estaba creado", flash[:notice]
    assert_equal [@o2.id], second.active_stops.map(&:order_id)
    assert_equal [@o1.id], first.active_stops.map(&:order_id)

    get admin_delivery_routes_path(date: @date.iso8601)
    assert_match "Chiara · Reparto 1", response.body
    assert_match "Chiara · Reparto 2", response.body
    assert_match "Pedidos sin asignar · 0", response.body

    get admin_delivery_route_path(second)
    assert_match "Chiara · Reparto 2", response.body
    assert_select "select[name=target_route_id] option", text: "Chiara · Reparto 1"

    get preview_admin_delivery_route_path(second)
    assert_match "su Reparto 2", response.body
    assert_no_match "SÍ, LO ENTREGUÉ", response.body
  end
end
