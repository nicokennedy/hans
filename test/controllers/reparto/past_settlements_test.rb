require "test_helper"
require_relative "../../support/delivery_route_helpers"

# R4: rendiciones pendientes de días anteriores. El repartidor completa cobros, gastos y fotos
# y envía la rendición; no registra entregas atrasadas. Fechas reales en cada operación.
class Reparto::PastSettlementsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include DeliveryRouteHelpers

  setup do
    setup_delivery_data
    ExpenseCategory.find_or_create_by!(name: "Logística y envíos")
    @yesterday = Date.current - 1
    @aurora = create_customer("Café Aurora", address: "Av. Colón 2345")
    @delivered_order = create_order(@aurora, date: @yesterday)
    @pending_order = create_order(create_customer("Bar La Esquina"), date: @yesterday)
    @past = DeliveryRoutes::Create.call(date: @yesterday, order_ids: [@delivered_order.id, @pending_order.id], user: @admin, driver: @driver).route
    @delivered_stop = @past.active_stops.find_by(order: @delivered_order)
    @pending_stop = @past.active_stops.find_by(order: @pending_order)
    # Entregado ayer (antes de este ajuste se registraba en el día).
    @delivered_stop.update!(delivery_status: "delivered", delivery_recorded_at: @yesterday.in_time_zone.change(hour: 11), delivery_recorded_by: @driver)
    sign_in @driver
  end

  test "the home lists previous routes with an unsent settlement and their totals" do
    collect(@past, @delivered_stop, 50_000)
    get reparto_root_path
    assert_match "Hoy no tenés reparto", response.body
    assert_select "#rendiciones-pendientes", text: /RENDICIONES PENDIENTES DE DÍAS ANTERIORES/
    assert_select "a[href=?]", reparto_route_settlement_path(@past), text: /REPARTO 1 · #{I18n.l(@yesterday, format: '%d\/%m')}.*Cobros \$500 · Gastos \$0.*Para entregar \$500.*Sin enviar/m
  end

  test "money registered later keeps the route date and uses the real date of each operation" do
    get reparto_stop_collection_confirm_path(@delivered_stop), params: { tipo: "parte", importe: "500" }
    assert_response :success
    token = css_select("input[name=request_token]").first["value"]
    params = { tipo: "parte", importe: "500", request_token: token }
    assert_difference -> { CustomerPayment.count }, 1 do
      post reparto_stop_collection_path(@delivered_stop), params: params
      post reparto_stop_collection_path(@delivered_stop), params: params
    end
    payment = CustomerPayment.last
    assert_equal Date.current, payment.paid_on, "el cobro va con la fecha real, no la del recorrido"
    assert_equal @yesterday, @past.reload.date

    DeliveryRoutes::Expenses.new(@past, @driver).record(concept: "Nafta", amount_cents: 10_000, request_token: SecureRandom.uuid)
    expense = @past.expenses.last
    assert_equal Date.current, expense.spent_at.to_date

    post reparto_route_settlement_confirm_path(@past)
    assert @past.reload.submitted?
    DeliveryRoutes::Settlements.new(@past, @admin).confirm(counted_cents: 40_000)
    assert_equal Date.current, expense.reload.expense.obligation.accrual_on
    assert_equal Date.current, OutgoingPayment.last.paid_on
  end

  test "after registering money on a previous route the driver goes back to that settlement" do
    collect(@past, @delivered_stop, 50_000)
    get saved_reparto_stop_path(@delivered_stop)
    assert_select "a[href=?]", reparto_route_settlement_path(@past), text: /VOLVER A LA RENDICIÓN/
    assert_no_match "Terminaste todas las paradas", response.body
  end

  test "late deliveries are blocked: the pending stop is shown for admin review" do
    get reparto_stop_path(@pending_stop)
    assert_response :success
    assert_match "la revisa administración", response.body
    assert_no_match "SÍ, LO ENTREGUÉ", response.body
    assert_select "a[href=?]", reparto_stop_collection_path(@pending_stop)

    post deliver_reparto_stop_path(@pending_stop)
    post record_not_delivered_reparto_stop_path(@pending_stop), params: { reason: "Estaba cerrado" }
    assert_equal "pending", @pending_stop.reload.delivery_status
    assert_equal "received", @pending_order.reload.status unless @pending_order.status == "delivered"
    assert_not DeliveryRoutes::Deliveries.new(@pending_stop, @driver).deliver.ok?

    get reparto_route_stops_path(@past)
    assert_match "REVISIÓN DE ADMINISTRACIÓN", response.body
    get reparto_route_path(@past)
    assert_match "1 parada quedó sin marcar: las revisa administración", response.body
    assert_no_match "PRÓXIMA PARADA", response.body
  end

  test "pending receipt photos can be completed and the settlement sent; then it leaves the list and is read only" do
    get reparto_route_settlement_path(@past)
    assert_select "a[href=?]", reparto_stop_photo_path(@delivered_stop)
    post reparto_stop_photo_path(@delivered_stop), params: { foto: receipt_photo, request_token: SecureRandom.uuid }
    assert_not @delivered_stop.reload.receipt_photo_pending?

    post reparto_route_settlement_confirm_path(@past)
    assert @past.reload.submitted?
    assert_redirected_to reparto_root_path
    follow_redirect!
    assert_match "Listo: enviaste la rendición del Reparto 1 del #{I18n.l(@yesterday, format: '%d/%m')}. Entregá $0 a administración.", response.body
    assert_select "#rendiciones-pendientes", 0
    get reparto_route_settlement_path(@past)
    assert_redirected_to reparto_root_path
    post reparto_stop_collection_path(@delivered_stop), params: { tipo: "identificar", importe: "100", request_token: SecureRandom.uuid }
    assert_equal 0, CustomerPayment.count
  end

  test "drivers only see their own previous routes" do
    emilio = create_driver("Emilio")
    emilio_past = DeliveryRoutes::Create.call(date: @yesterday, order_ids: [], user: @admin, driver: emilio).route
    get reparto_route_settlement_path(emilio_past)
    assert_redirected_to reparto_root_path
    get reparto_root_path
    assert_select "a[href=?]", reparto_route_settlement_path(emilio_past), 0

    sign_in emilio
    get reparto_root_path
    assert_select "a[href=?]", reparto_route_settlement_path(emilio_past)
    assert_select "a[href=?]", reparto_route_settlement_path(@past), 0
    get reparto_stop_collection_path(@delivered_stop)
    assert_redirected_to reparto_root_path
  end

  test "confirmed or submitted previous routes are not pending; legacy routes without driver are ignored" do
    DeliveryRoutes::Settlements.new(@past, @driver).submit
    legacy = DeliveryRoute.new(date: @yesterday - 5, created_by: @admin)
    legacy.save!(validate: false)
    get reparto_root_path
    assert_select "#rendiciones-pendientes", 0
  end

  test "admin sees the warning and can filter unsent settlements by state, driver and date" do
    collect(@past, @delivered_stop, 50_000)
    emilio = create_driver("Emilio")
    DeliveryRoutes::Create.call(date: @yesterday - 3, order_ids: [], user: @admin, driver: emilio)
    sign_in @admin
    get admin_delivery_routes_path
    assert_match "Rendiciones sin enviar de días anteriores", response.body

    get settlements_admin_delivery_routes_path(filtro: "sin_enviar")
    assert_match "Chiara · Reparto 1", response.body
    assert_match "Emilio · Reparto 1", response.body
    assert_match "Sin enviar", response.body
    assert_match "$500", response.body

    get settlements_admin_delivery_routes_path(filtro: "sin_enviar", repartidor: emilio.id)
    assert_equal ["Emilio · Reparto 1"], css_select("tbody tr td:nth-child(2) a").map(&:text)
    get settlements_admin_delivery_routes_path(filtro: "sin_enviar", desde: @yesterday.iso8601, hasta: @yesterday.iso8601)
    assert_equal ["Chiara · Reparto 1"], css_select("tbody tr td:nth-child(2) a").map(&:text)
  end
end
