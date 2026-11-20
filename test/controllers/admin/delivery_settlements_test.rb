require "test_helper"
require_relative "../../support/delivery_route_helpers"

# R4 en Administración → Repartos: cobros, gastos, fotos, cierre e historial de rendiciones.
class Admin::DeliverySettlementsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include DeliveryRouteHelpers

  setup do
    setup_delivery_data
    @category = ExpenseCategory.find_or_create_by!(name: "Logística y envíos")
    @aurora = create_customer("Café Aurora", address: "Av. Colón 2345")
    @order = create_order(@aurora)
    @route = DeliveryRoutes::Create.call(date: @date, order_ids: [@order.id], user: @admin, driver: @driver).route
    @stop = @route.active_stops.first
    @collection = collect(@route, @stop, 150_000).collection
    DeliveryRoutes::Expenses.new(@route, @driver).record(concept: "Nafta", amount_cents: 20_000, request_token: SecureRandom.uuid)
  end

  test "the route page shows collections, expenses, receipts and the settlement" do
    DeliveryRoutes::Deliveries.new(@stop, @driver).deliver
    photo = DeliveryRoutes::Photos.new(@route, @driver).attach(@stop, receipt_photo, request_token: SecureRandom.uuid).photo
    sign_in @admin
    get admin_delivery_route_path(@route)
    assert_response :success
    assert_match "Cobros y rendición", response.body
    assert_match "$1,500", response.body
    assert_match "Nafta", response.body
    assert_match "$1,300", response.body
    assert_select "img[src=?]", delivery_photo_path(photo)
    assert_match "El repartidor todavía no envió la rendición", response.body

    get delivery_photo_path(photo)
    assert_response :success
    assert_equal "image/jpeg", response.media_type
    assert_match "no-store", response.headers["Cache-Control"]
  end

  test "receipt photos are never public: only admin and the route's driver" do
    photo = DeliveryRoutes::Photos.new(@route, @driver).attach(@stop, receipt_photo, request_token: SecureRandom.uuid).photo
    get delivery_photo_path(photo)
    assert_redirected_to new_user_session_path
    sign_in create_driver("Emilio")
    get delivery_photo_path(photo)
    assert_response :not_found
    sign_in User.create!(email: "ph-prod@example.com", password: "password123", role: "production")
    get delivery_photo_path(photo)
    assert_response :not_found
    sign_in @driver
    get delivery_photo_path(photo)
    assert_response :success
  end

  test "admin corrects a collection with a reason before the close and the settlement is recalculated" do
    DeliveryRoutes::Settlements.new(@route, @driver).submit
    sign_in @admin
    get edit_admin_delivery_route_collection_path(@route, @collection)
    assert_response :success
    token = css_select("input[name=request_token]").first["value"]
    patch admin_delivery_route_collection_path(@route, @collection), params: { importe: "1.200", motivo: "", request_token: token, asignar: { @order.id => "1.200" } }
    assert_not @collection.reload.voided?
    patch admin_delivery_route_collection_path(@route, @collection), params: { importe: "1.200", motivo: "Contado en la oficina", request_token: token, asignar: { @order.id => "1.200" } }
    assert_redirected_to admin_delivery_route_path(@route, anchor: "rendicion")
    assert @collection.reload.voided?
    assert_equal 120_000, DeliveryRoutes::Settlement.new(@route).collected_cents
    assert_equal 120_000, @order.reload.amount_paid_cents
  end

  test "admin registers an expense above the available cash only as an explicit exception" do
    sign_in @admin
    params = { concepto: "Gomería", importe: "5.000", request_token: SecureRandom.uuid }
    post admin_delivery_route_expenses_path(@route), params: params
    assert_match "Para registrarlo igual", flash[:alert]
    post admin_delivery_route_expenses_path(@route), params: params.merge(excepcion: "1", motivo_excepcion: "Pinchadura")
    assert DeliveryExpense.last.admin_exception?
    get admin_delivery_route_path(@route)
    assert_match "Importe pendiente de resolver", response.body
  end

  test "confirming the close: counted cash, difference with reason, expenses once, then read only" do
    DeliveryRoutes::Settlements.new(@route, @driver).submit
    sign_in @admin
    get admin_delivery_route_path(@route)
    assert_select "form[action=?]", confirm_settlement_admin_delivery_route_path(@route)
    assert_select "select[name='categorias[#{@route.expenses.first.id}]'] option[selected]", text: "Logística y envíos"

    post confirm_settlement_admin_delivery_route_path(@route), params: { contado: "1.200" }
    assert_match "diferencia de caja", flash[:alert]
    assert_difference -> { Expense.count }, 1 do
      post confirm_settlement_admin_delivery_route_path(@route), params: { contado: "1.200", nota: "Faltan $100", categorias: { @route.expenses.first.id => @category.id } }
      post confirm_settlement_admin_delivery_route_path(@route), params: { contado: "1.200", nota: "Faltan $100" }
    end
    @route.reload
    assert @route.confirmed?
    assert_equal -10_000, @route.difference_cents
    get admin_delivery_route_path(@route)
    assert_match "faltante", response.body
    assert_select "a", text: "Corregir", count: 0
    get edit_admin_delivery_route_collection_path(@route, @collection)
    token = css_select("input[name=request_token]").first["value"]
    patch admin_delivery_route_collection_path(@route, @collection), params: { importe: "1.000", motivo: "x", request_token: token }
    assert_match "La rendición ya está cerrada", flash[:alert]

    get settlements_admin_delivery_routes_path(filtro: "diferencias")
    assert_response :success
    assert_match "Chiara · Reparto 1", response.body
    assert_match "Faltan $100", response.body
  end

  test "the history lists pending settlements and overdue routes" do
    DeliveryRoutes::Settlements.new(@route, @driver).submit
    old = DeliveryRoutes::Create.call(date: Date.current - 2, order_ids: [], user: @admin, driver: @driver).route
    sign_in @admin
    get settlements_admin_delivery_routes_path
    assert_match "Chiara · Reparto 1", response.body
    assert_match "Sin rendición enviada de días anteriores", response.body
    assert_select "a[href=?]", admin_delivery_route_path(old, anchor: "rendicion")
    get admin_delivery_routes_path
    assert_match "Rendiciones sin enviar de días anteriores", response.body
  end

  test "the order page warns not to enter the driver's cash again" do
    sign_in @admin
    get admin_order_path(@order)
    assert_select "#delivery-cash-warning", text: /Chiara · Reparto 1/
    assert_match "Cobro de reparto: Chiara · Reparto 1", response.body
  end

  test "only admins reach the money screens of Repartos" do
    production = User.create!(email: "st-prod@example.com", password: "password123", role: "production")
    { @driver => reparto_root_path, production => admin_production_index_path }.each do |user, fallback|
      sign_in user
      [-> { get settlements_admin_delivery_routes_path },
       -> { get new_admin_delivery_route_collection_path(@route) },
       -> { post confirm_settlement_admin_delivery_route_path(@route), params: { contado: "0" } },
       -> { post admin_delivery_route_expenses_path(@route), params: { concepto: "x", importe: "1", request_token: "t" } }].each do |request|
        request.call
        assert_redirected_to fallback
      end
    end
    assert_not @route.reload.confirmed?
  end
end
