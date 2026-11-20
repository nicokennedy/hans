require "test_helper"
require_relative "../../support/delivery_route_helpers"

# El repartidor con varios repartos hoy elige cuál abrir y cada uno muestra solo sus paradas.
class Reparto::SeveralRoutesTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include DeliveryRouteHelpers

  setup do
    setup_delivery_data
    @today = Date.current
    @emilio = create_driver("Emilio")
    @first_orders = [create_order(create_customer("Café Aurora", address: "Av. Colón 2345"), date: @today),
                     create_order(create_customer("Bar La Esquina"), date: @today)]
    @second_order = create_order(create_customer("Hotel Costa", address: "Mitre 10"), date: @today)
    @r1 = DeliveryRoutes::Create.call(date: @today, order_ids: @first_orders.map(&:id), user: @admin, driver: @driver).route
    @r2 = DeliveryRoutes::Create.call(date: @today, order_ids: [@second_order.id], user: @admin, driver: @driver).route
    @emilio_route = DeliveryRoutes::Create.call(date: @today, order_ids: [create_order(create_customer("Kiosco Sur"), date: @today).id],
                                                user: @admin, driver: @emilio).route
  end

  test "the driver chooses which of today's routes to open" do
    sign_in @driver
    get reparto_root_path
    assert_response :success
    assert_match "Hoy tenés <strong>2 repartos</strong>", response.body
    assert_select "a[href=?]", reparto_route_path(@r1), text: /REPARTO 1.*2 paradas · Sin empezar/m
    assert_select "a[href=?]", reparto_route_path(@r2), text: /REPARTO 2.*1 parada · Sin empezar/m
    assert_no_match "Kiosco Sur", response.body

    get reparto_route_path(@r2)
    assert_response :success
    assert_match "REPARTO 2 · HOY", response.body
    assert_match "Hotel Costa", response.body
    assert_no_match "Café Aurora", response.body

    get reparto_route_stops_path(@r1)
    assert_match "Café Aurora", response.body
    assert_match "Bar La Esquina", response.body
    assert_no_match "Hotel Costa", response.body
  end

  test "delivering in the second route marks only that stop and keeps the first untouched" do
    sign_in @driver
    stop = @r2.active_stops.first
    get reparto_stop_path(stop)
    assert_match "REPARTO 2 · PARADA 1 DE 1", response.body
    assert_select "a[href=?]", reparto_route_stops_path(@r2), text: "◀ VOLVER A LA LISTA"

    assert_difference -> { DeliveryEvent.where(event_type: "stop_delivered").count }, 1 do
      post deliver_reparto_stop_path(stop)
      post deliver_reparto_stop_path(stop)
    end
    assert_equal "delivered", stop.reload.delivery_status
    assert_equal "delivered", @second_order.reload.status
    assert @r1.active_stops.all? { |s| s.delivery_status == "pending" }

    get saved_reparto_stop_path(stop)
    assert_match "¡Terminaste todas las paradas de este reparto!", response.body
    assert_select "a[href=?]", reparto_route_path(@r2), text: "VOLVER AL INICIO"
    assert_select "a[href=?]", reparto_root_path, text: "MIS REPARTOS DE HOY"

    get reparto_root_path
    assert_select "a[href=?]", reparto_route_path(@r2), text: /Terminado/
  end

  test "a driver cannot open another driver's route or stops" do
    sign_in @emilio
    get reparto_route_path(@r1)
    assert_redirected_to reparto_root_path
    get reparto_route_stops_path(@r2)
    assert_redirected_to reparto_root_path
    post deliver_reparto_stop_path(@r2.active_stops.first)
    assert_redirected_to reparto_root_path
    assert_equal "pending", @r2.active_stops.first.reload.delivery_status

    get reparto_root_path
    assert_match "Kiosco Sur", response.body
    assert_no_match "Hoy tenés", response.body
  end

  test "routes of other days are not offered" do
    tomorrow = DeliveryRoutes::Create.call(date: @today + 1, order_ids: [], user: @admin, driver: @driver).route
    sign_in @driver
    get reparto_route_path(tomorrow)
    assert_redirected_to reparto_root_path
    get reparto_root_path
    assert_select "a[href=?]", reparto_route_path(tomorrow), 0
  end

  test "the old list link without a route goes back to the choice when there are several" do
    sign_in @driver
    get reparto_stops_path
    assert_redirected_to reparto_root_path
  end

  test "admins, production and customers cannot use the driver's route screens" do
    production = User.create!(email: "sr-prod@example.com", password: "password123", role: "production")
    customer = User.create!(email: "sr-cust@example.com", password: "password123", role: "customer", customer: create_customer("Cliente Portal"))
    sign_in @admin
    get reparto_route_path(@r1)
    assert_redirected_to admin_delivery_routes_path
    { production => admin_production_index_path, customer => dashboard_path }.each do |user, fallback|
      sign_in user
      get reparto_route_path(@r1)
      assert_redirected_to fallback
    end
  end
end
