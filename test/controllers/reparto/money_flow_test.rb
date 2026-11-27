require "test_helper"
require_relative "../../support/delivery_route_helpers"

# R4 en el celular: entregar → ¿te pagaron? → confirmar → (foto) → listo; gastos y rendición.
class Reparto::MoneyFlowTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include DeliveryRouteHelpers

  setup do
    setup_delivery_data
    @today = Date.current
    @aurora = create_customer("Café Aurora", address: "Av. Colón 2345")
    @old = create_order(@aurora, date: @today - 7)
    @order = create_order(@aurora, date: @today)
    @esquina_order = create_order(create_customer("Bar La Esquina"), date: @today)
    @route = DeliveryRoutes::Create.call(date: @today, order_ids: [@order.id, @esquina_order.id], user: @admin, driver: @driver).route
    @stop = @route.active_stops.find_by(order: @order)
    sign_in @driver
  end

  def confirm_and_save(params)
    get reparto_stop_collection_confirm_path(@stop), params: params
    assert_response :success
    token = css_select("input[name=request_token]").first["value"]
    form = css_select("form[action='#{reparto_stop_collection_path(@stop)}'] input[type=hidden]").to_h { |i| [i["name"], i["value"]] }
    form
  end

  test "delivered and paid in full: the amount is confirmed before saving, double tap saves once" do
    post deliver_reparto_stop_path(@stop)
    follow_redirect!
    assert_match "¿Te pagaron?", response.body
    assert_match "Además debe de 1 pedido anterior", response.body
    assert_match "Solo efectivo", response.body

    form = confirm_and_save(tipo: "todo")
    assert_match "$2.000", response.body
    assert_difference -> { CustomerPayment.count }, 1 do
      post reparto_stop_collection_path(@stop), params: form
      post reparto_stop_collection_path(@stop), params: form
    end
    assert_redirected_to saved_reparto_stop_path(@stop, ya: 1)
    follow_redirect!
    assert_match "Cobraste <strong>$2.000</strong>", response.body
    assert_equal "paid", @order.reload.payment_status
  end

  test "partial payment goes to the receipt photo; a failed upload leaves it pending and lets the driver go on" do
    post deliver_reparto_stop_path(@stop)
    get reparto_stop_collection_amount_path(@stop, tipo: "parte")
    assert_match "¿Cuánto te pagaron?", response.body
    form = confirm_and_save(tipo: "parte", importe: "500")
    post reparto_stop_collection_path(@stop), params: form
    assert_redirected_to reparto_stop_photo_path(@stop)
    follow_redirect!
    assert_match "Sacale una foto al remito firmado", response.body
    assert_select "input[type=file][capture=environment][accept='image/*']"

    RetailCatalog::PhotoStorage.stub(:enabled?, false) do
      post reparto_stop_photo_path(@stop), params: { foto: receipt_photo, request_token: SecureRandom.uuid }
    end
    assert_redirected_to saved_reparto_stop_path(@stop)
    follow_redirect!
    assert_match "Quedó pendiente", response.body
    assert_match "Falta la foto del remito firmado", response.body
    assert_match "SIGUIENTE PARADA", response.body

    post reparto_stop_photo_path(@stop), params: { foto: receipt_photo, request_token: SecureRandom.uuid }
    follow_redirect!
    assert_match "la foto del remito quedó guardada", response.body
    assert_not @stop.reload.receipt_photo_pending?
  end

  test "not paid: no money, straight to the photo, and 'no quiso firmar' is accepted" do
    post deliver_reparto_stop_path(@stop)
    assert_no_difference -> { CustomerPayment.count } do
      post reparto_stop_collection_unpaid_path(@stop)
    end
    assert_redirected_to reparto_stop_photo_path(@stop)
    post reparto_stop_photo_no_signature_path(@stop)
    follow_redirect!
    assert_match "el cliente no quiso firmar", response.body
  end

  test "pays previous debts: choose orders, see the split and the credit, confirm" do
    get reparto_stop_collection_orders_path(@stop), params: { tipo: "otro", importe: "4.500" }
    assert_response :success
    assert_match "¿Qué pedidos paga?", response.body
    assert_select "input[name='asignar[#{@order.id}]'][value='2.000']"
    assert_select "input[name='asignar[#{@old.id}]'][value='2.000']"

    form = confirm_and_save(tipo: "otro", importe: "4.500", asignar: { @order.id => "2.000", @old.id => "2.000" })
    assert_match "Queda a favor del cliente", response.body
    post reparto_stop_collection_path(@stop), params: form
    collection = DeliveryCollection.last
    assert_equal [450_000, 50_000], [collection.amount_cents, collection.credit_cents]
    assert_equal [0, 0], [@order.reload.balance_due_cents, @old.reload.balance_due_cents]
  end

  test "unknown order: registered as credit to identify" do
    form = confirm_and_save(tipo: "identificar", importe: "1000")
    assert_match "A identificar", response.body
    post reparto_stop_collection_path(@stop), params: form
    assert DeliveryCollection.last.unidentified?
    assert_equal 200_000, @order.reload.balance_due_cents
  end

  test "server validates amounts: a partial that is the whole balance is refused" do
    get reparto_stop_collection_confirm_path(@stop), params: { tipo: "parte", importe: "2000" }
    assert_redirected_to reparto_stop_collection_amount_path(@stop, tipo: "parte")
    post reparto_stop_collection_path(@stop), params: { tipo: "parte", importe: "abc", request_token: SecureRandom.uuid }
    assert_equal 0, CustomerPayment.count
  end

  test "the driver corrects a collection with a reason before submitting" do
    collection = collect(@route, @stop, 150_000).collection
    get reparto_stop_path(@stop)
    assert_select "a[href=?]", reparto_collection_correction_path(collection)
    get reparto_collection_correction_confirm_path(collection), params: { importe: "1000", motivo: "Me equivoqué de importe" }
    assert_response :success
    assert_match "¿Corregimos el cobro?", response.body
    token = css_select("input[name=request_token]").first["value"]
    post reparto_collection_correction_path(collection), params: { importe: "1.000", motivo: "Otro motivo", motivo_texto: "Me equivoqué de importe", request_token: token }
    assert_redirected_to reparto_stop_path(@stop)
    assert collection.reload.voided?
    assert_equal 100_000, @order.reload.amount_paid_cents
  end

  test "expenses: limited to the route cash, confirmed before saving" do
    get reparto_route_expenses_path(@route)
    assert_match "Te quedan <strong>$0</strong>", response.body
    get reparto_route_expense_confirm_path(@route), params: { concepto: "Nafta", importe: "500" }
    assert_redirected_to reparto_route_new_expense_path(@route, concepto: "Nafta", importe: "500")
    follow_redirect!
    assert_match "Supera el efectivo disponible ($0). Avisale a administración.", response.body

    collect(@route, @stop, 200_000)
    get reparto_route_expense_confirm_path(@route), params: { concepto: "Nafta", importe: "500" }
    assert_match "¿Pagaste esto con la plata del reparto?", response.body
    token = css_select("input[name=request_token]").first["value"]
    params = { concepto: "Otro", concepto_texto: "Nafta", importe: "500", request_token: token }
    assert_difference -> { DeliveryExpense.count }, 1 do
      post reparto_route_expenses_path(@route), params: params
      post reparto_route_expenses_path(@route), params: params
    end
  end

  test "settlement: shows collections, expenses and the cash to deliver, then sends and locks" do
    collect(@route, @stop, 200_000)
    DeliveryRoutes::Expenses.new(@route, @driver).record(concept: "Nafta", amount_cents: 30_000, request_token: SecureRandom.uuid)
    get reparto_route_settlement_path(@route)
    assert_match "Mi rendición", response.body
    assert_match "Café Aurora", response.body
    assert_match "$1.700", response.body
    assert_match "Te faltan 2 paradas por marcar", response.body

    get reparto_route_settlement_confirm_path(@route)
    assert_match "¿Terminaste este reparto?", response.body
    post reparto_route_settlement_confirm_path(@route)
    post reparto_route_settlement_confirm_path(@route)
    assert @route.reload.submitted?
    assert_equal 1, @route.events.where(event_type: "settlement_submitted").count
    follow_redirect!
    assert_match "Enviada a administración", response.body

    get reparto_stop_path(@stop)
    assert_match "acá solo se puede mirar", response.body
    assert_no_match "SÍ, LO ENTREGUÉ", response.body
    post reparto_stop_collection_path(@stop), params: { tipo: "identificar", importe: "100", request_token: SecureRandom.uuid }
    assert_equal 1, CustomerPayment.count
  end

  test "other drivers, admins, production and customers cannot use these screens" do
    emilio = create_driver("Emilio")
    sign_in emilio
    get reparto_stop_collection_path(@stop)
    assert_redirected_to reparto_root_path
    post reparto_stop_collection_path(@stop), params: { tipo: "identificar", importe: "100", request_token: SecureRandom.uuid }
    get reparto_route_settlement_path(@route)
    assert_redirected_to reparto_root_path
    assert_equal 0, CustomerPayment.count

    sign_in @admin
    get reparto_stop_collection_path(@stop)
    assert_redirected_to admin_delivery_routes_path
    production = User.create!(email: "mf-prod@example.com", password: "password123", role: "production")
    sign_in production
    get reparto_route_expenses_path(@route)
    assert_redirected_to admin_production_index_path
  end
end
