require "test_helper"
require_relative "../../support/delivery_route_helpers"

class Reparto::StopsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include DeliveryRouteHelpers

  setup do
    setup_delivery_data
    @today = Date.current
    @emilio = create_driver("Emilio")
    @aurora = create_customer("Café Aurora", address: "Av. Colón 2345", delivery_instructions: "Timbre verde")
    @esquina = create_customer("Bar La Esquina")
    @o1 = create_order(@aurora, date: @today)
    @o2 = create_order(@esquina, date: @today)
    @o3 = create_order(create_customer("Hotel Costa"), date: @today)
    @route = DeliveryRoutes::Create.call(date: @today, order_ids: [@o1.id, @o2.id], user: @admin, driver: @driver).route
    @emilio_route = DeliveryRoutes::Create.call(date: @today, order_ids: [@o3.id], user: @admin, driver: @emilio).route
    @stop = @route.active_stops.find_by(order: @o1)
  end

  test "the driver sees only their route of today, with the next stop" do
    sign_in @driver
    get reparto_root_path
    assert_response :success
    assert_match "PRÓXIMA PARADA", response.body
    assert_match @route.active_stops.first.display_name, response.body
    assert_no_match "Hotel Costa", response.body

    get reparto_stops_path
    assert_match "Bar La Esquina", response.body
    assert_no_match "Hotel Costa", response.body

    get reparto_stop_path(@stop)
    assert_response :success
    assert_match "LLEVÁS", response.body
    assert_match "Timbre verde", response.body
    assert_match "CÓMO LLEGAR", response.body
    assert_match "SÍ, LO ENTREGUÉ", response.body
  end

  test "a driver cannot open or change another driver's stop" do
    other_stop = @emilio_route.active_stops.first
    sign_in @driver
    get reparto_stop_path(other_stop)
    assert_redirected_to reparto_root_path
    post deliver_reparto_stop_path(other_stop)
    assert_redirected_to reparto_root_path
    assert_equal "pending", other_stop.reload.delivery_status
    assert_equal "received", @o3.reload.status
  end

  test "routes of other days are not shown to the driver" do
    @route.update_column(:date, @today + 1)
    sign_in @driver
    get reparto_root_path
    assert_match "Hoy no tenés reparto", response.body
    get reparto_stop_path(@stop)
    assert_redirected_to reparto_root_path
  end

  test "confirming a delivery marks the order delivered and shows the saved screen, once" do
    sign_in @driver
    post deliver_reparto_stop_path(@stop)
    assert_redirected_to saved_reparto_stop_path(@stop)
    follow_redirect!
    assert_match "Listo, quedó guardado", response.body
    assert_match "SIGUIENTE PARADA", response.body
    assert_equal "delivered", @o1.reload.status

    post deliver_reparto_stop_path(@stop)
    follow_redirect!
    assert_match "Ya estaba guardado", response.body
    assert_equal 1, @route.events.where(event_type: "stop_delivered").count
  end

  test "not delivered: pick a reason, the order stays as it was" do
    sign_in @driver
    get not_delivered_reparto_stop_path(@stop)
    assert_match "¿Qué pasó?", response.body
    post record_not_delivered_reparto_stop_path(@stop), params: { reason: "Estaba cerrado" }
    follow_redirect!
    assert_match "No se pudo: Estaba cerrado", response.body
    assert_equal "received", @o1.reload.status

    post record_not_delivered_reparto_stop_path(@stop), params: { reason: "Me aburrí" }
    assert_redirected_to reparto_stop_path(@stop)
    assert_equal "Elegí el motivo.", flash[:alert]
  end

  test "admins cannot record deliveries from the driver portal" do
    sign_in @admin
    post deliver_reparto_stop_path(@stop)
    assert_redirected_to admin_delivery_routes_path
    assert_equal "pending", @stop.reload.delivery_status
    assert_equal "received", @o1.reload.status
  end

  test "the admin preview shows statuses and has no delivery buttons" do
    DeliveryRoutes::Deliveries.new(@stop, @driver).deliver
    sign_in @admin
    get preview_admin_delivery_route_path(@route)
    assert_match "VISTA PREVIA DE ADMINISTRACIÓN", response.body
    assert_match "ENTREGADO", response.body
    get preview_admin_delivery_route_path(@route, stop_id: @stop.id)
    assert_no_match "SÍ, LO ENTREGUÉ", response.body
    assert_select "form", count: 0
  end

  test "drivers cannot reach the admin routes or users" do
    sign_in @driver
    [admin_delivery_routes_path, admin_delivery_route_path(@emilio_route), preview_admin_delivery_route_path(@emilio_route), admin_users_path].each do |path|
      get path
      assert_redirected_to reparto_root_path
    end
    patch transfer_admin_delivery_route_stop_path(@route, @stop), params: { target_route_id: @emilio_route.id }
    assert_redirected_to reparto_root_path
    assert_not @stop.reload.removed?
  end

  test "an inactive driver is signed out" do
    sign_in @driver
    @driver.update!(active: false)
    get reparto_root_path
    assert_redirected_to new_user_session_path
  end
end
