require "test_helper"
require_relative "../../support/delivery_route_helpers"

class Reparto::RouteImprovementsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include DeliveryRouteHelpers

  setup do
    setup_delivery_data
    @customer = create_customer("Café del Puerto", address: "Av. Colón 1234")
    @orders = [create_order(@customer, date: Date.current), create_order(@customer, date: Date.current, quantity: 3)]
    @route = DeliveryRoutes::Create.call(date: Date.current, order_ids: @orders.map(&:id), user: @admin, driver: @driver).route
    @stops = @route.active_stops.to_a
    @leader = @stops.first
  end

  test "admin groups and ungroups, all orders stay assigned and appear on one consolidated receipt" do
    sign_in @admin
    get admin_delivery_route_path(@route)
    assert_response :success
    assert_select "form[action=?]", group_admin_delivery_route_stops_path(@route)
    post group_admin_delivery_route_stops_path(@route), params: { stop_ids: @stops.map(&:id) }
    assert_redirected_to admin_delivery_route_path(@route)
    assert_equal [@leader.id], @route.active_stops.pluck(:id)
    assert_empty DeliveryRoute.unassigned_orders_for(Date.current)
    assert_not DeliveryRoutes::Create.call(date: Date.current, order_ids: [@stops.last.order_id], user: @admin, driver: @driver).ok?

    get receipt_admin_delivery_route_stop_path(@route, @leader)
    assert_response :success
    @orders.each { |order| assert_includes response.body, order.number }
    assert_select ".reparto-qty", text: "5", count: 2

    patch ungroup_admin_delivery_route_stop_path(@route, @leader)
    assert_redirected_to admin_delivery_route_path(@route)
    assert_equal @stops.map(&:id), @route.active_stops.pluck(:id)
  end

  test "a grouped successful delivery leaves stock intact and collects the remaining balance once" do
    existing = CustomerAccounts::RegisterPayment.call(customer: @customer, user: @admin,
      amount_cents: 50_000, paid_on: Date.current, payment_method: "cash_on_delivery",
      allocations: { @orders.last.id => 50_000 }, request_token: SecureRandom.uuid)
    assert existing.ok?
    group_stops
    sign_in @driver

    get reparto_stop_path(@stops.last)
    assert_redirected_to reparto_root_path
    get reparto_stop_path(@leader)
    assert_response :success
    assert_select ".reparto-qty", text: "5", count: 1
    get reparto_stop_receipt_path(@leader)
    assert_response :success

    assert_no_difference "StockMovement.count" do
      post deliver_reparto_stop_path(@leader)
      assert_redirected_to reparto_stop_collection_path(@leader)
      post deliver_reparto_stop_path(@leader)
    end
    assert_equal ["delivered", "delivered"], @orders.map { |order| order.reload.status }
    amount = @orders.sum(&:balance_due_cents)
    get reparto_stop_collection_confirm_path(@leader), params: { tipo: "todo" }
    assert_response :success
    assert_select "form[enctype='multipart/form-data']"
    token = SecureRandom.uuid
    assert_difference "CustomerPayment.count", 1 do
      post reparto_stop_collection_path(@leader), params: { tipo: "todo", request_token: token, evidence_gallery: receipt_photo }
      post reparto_stop_collection_path(@leader), params: { tipo: "todo", request_token: token }
    end
    collection = @route.collections.sole
    assert_equal [amount, 2], [collection.amount_cents, collection.allocation_map.size]
    assert collection.evidence.attached?
    assert_empty @leader.reload.delivery_orders.reject { |order| order.balance_due_cents.zero? }

    sign_out @driver
    sign_in create_driver("Otro repartidor")
    get delivery_collection_evidence_path(collection)
    assert_response :not_found
    sign_in @admin
    get admin_delivery_route_collection_path(@route, collection)
    assert_response :success
    assert_select "a[href=?]", delivery_collection_evidence_path(collection)
    get delivery_collection_evidence_path(collection)
    assert_response :success
    assert_match "no-store", response.headers.fetch("Cache-Control")
  end

  test "failed delivery leaves both orders intact, and a later partial payment can be saved without the photo" do
    group_stops
    sign_in @driver
    assert_no_difference ["CustomerPayment.count", "StockMovement.count"] do
      post record_not_delivered_reparto_stop_path(@leader), params: { reason: "Estaba cerrado" }
    end
    assert_equal ["received", "received"], @orders.map { |order| order.reload.status }

    post deliver_reparto_stop_path(@leader)
    post reparto_stop_collection_path(@leader), params: {
      tipo: "parte", importe: "2.500", request_token: SecureRandom.uuid, evidence_camera: receipt_photo("document.pdf")
    }
    assert_redirected_to reparto_stop_photo_path(@leader)
    assert_includes flash[:alert], "El cobro se guardó sin la foto"
    collection = @route.collections.sole
    assert_equal 2, collection.allocation_map.size
    assert_not collection.evidence.attached?
    assert @leader.reload.receipt_photo_pending?
    photos = DeliveryRoutes::Photos.new(@route, @driver)
    assert photos.attach(@leader, receipt_photo, request_token: SecureRandom.uuid).ok?
    assert photos.attach(@leader, receipt_photo, request_token: SecureRandom.uuid).already
    assert_equal 1, @leader.photos.count
  end

  test "unpaid grouped delivery needs just its signed receipt and creates no payment" do
    group_stops
    sign_in @driver
    post deliver_reparto_stop_path(@leader)
    assert_no_difference "CustomerPayment.count" do
      post reparto_stop_collection_unpaid_path(@leader)
    end
    assert_redirected_to reparto_stop_photo_path(@leader)
    assert_equal ["delivered", "delivered"], @orders.map { |order| order.reload.status }
  end

  test "incomes fund expenses, remain auditable and do not post separately to finance" do
    sign_in @driver
    get reparto_route_incomes_path(@route)
    assert_response :success
    get new_reparto_route_income_path(@route)
    assert_response :success
    assert_select "input[type=radio]", count: 3

    assert_no_difference ["CustomerPayment.count", "Payment.count", "Expense.count", "Obligation.count"] do
      %w[additional_collection hans_cash other].each do |kind|
        post reparto_route_incomes_path(@route), params: {
          kind: kind, description: "Prueba #{kind}", importe: "300", request_token: SecureRandom.uuid
        }
        assert_redirected_to reparto_route_incomes_path(@route)
      end
    end
    expense = DeliveryRoutes::Expenses.new(@route, @driver).record(
      concept: "Estacionamiento", amount_cents: 25_000, request_token: SecureRandom.uuid
    )
    assert expense.ok?, expense.errors.inspect
    assert_equal 65_000, DeliveryRoutes::Settlement.new(@route).to_deliver_cents

    old = @route.incomes.first
    assert DeliveryRoutes::Settlements.new(@route, @driver).submit.ok?
    correction = { kind: old.kind, description: "Importe corregido", importe: "500", motivo: "Recuento", request_token: SecureRandom.uuid }
    patch reparto_route_income_path(@route, old), params: correction
    assert_response :unprocessable_entity
    assert_not old.reload.voided?
    photos = DeliveryRoutes::Photos.new(@route, @driver)
    assert_not photos.no_signature(@leader).ok?
    assert DeliveryRoutes::Photos.new(@route, @admin).no_signature(@leader).ok?

    sign_out @driver
    sign_in @admin
    patch admin_delivery_route_income_path(@route, old), params: correction
    assert_redirected_to admin_delivery_route_incomes_path(@route)
    assert old.reload.voided?
    assert_equal old, @route.incomes.last.replaces
    sign_in @admin
    category = ExpenseCategory.find_or_create_by!(name: "Logística y envíos")
    assert_difference "Expense.count", 1 do
      closed = DeliveryRoutes::Settlements.new(@route, @admin).confirm(counted_cents: 85_000, categories: { expense.expense.id => category.id })
      assert closed.ok?, closed.errors.inspect
    end
    assert_equal [110_000, 85_000], @route.reload.attributes.values_at("other_income_cents", "expected_cash_cents")
    patch admin_delivery_route_income_path(@route, @route.incomes.last), params: correction.merge(request_token: SecureRandom.uuid)
    assert_response :unprocessable_entity
  end

  private

  def group_stops
    result = DeliveryRoutes::Editor.new(@route, @admin).group(@stops.map(&:id))
    assert result.ok?, result.errors.inspect
  end
end
