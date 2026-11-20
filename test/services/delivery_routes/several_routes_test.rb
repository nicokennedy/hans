require "test_helper"
require_relative "../../support/delivery_route_helpers"

# Varios recorridos el mismo día, también del mismo repartidor: Chiara sale con 6 pedidos,
# vuelve a HANS y sale de nuevo con otros 4. Cada recorrido es independiente.
class DeliveryRoutes::SeveralRoutesTest < ActiveSupport::TestCase
  include DeliveryRouteHelpers

  setup do
    setup_delivery_data
    @orders = Array.new(10) { |i| create_order(create_customer("Cliente #{format('%02d', i)}", address: "Calle #{i} 100")) }
  end

  def create(orders, driver: @driver, token: nil)
    DeliveryRoutes::Create.call(date: @date, order_ids: orders.map(&:id), user: @admin, driver: driver, creation_token: token)
  end

  test "the same driver can have two routes on the same day, numbered and independent" do
    first = create(@orders.first(6))
    assert first.ok?, first.errors.inspect
    assert_equal 4, DeliveryRoute.unassigned_orders_for(@date).count

    second = create(@orders.last(4))
    assert second.ok?, second.errors.inspect
    assert_equal 0, DeliveryRoute.unassigned_orders_for(@date).count

    r1 = first.route.reload
    r2 = second.route.reload
    assert_not_equal r1.id, r2.id
    assert_equal ["Reparto 1", "Reparto 2"], [r1.label, r2.label]
    assert_equal "Chiara · Reparto 2", r2.title
    assert_equal @orders.first(6).map(&:id).sort, r1.active_stops.map(&:order_id).sort
    assert_equal @orders.last(4).map(&:id).sort, r2.active_stops.map(&:order_id).sort
    assert_equal [1, 2, 3, 4], r2.active_stops.map(&:position)
    assert_equal ["route_created"], r1.events.map(&:event_type)
    assert_equal ["route_created"], r2.events.map(&:event_type)
    assert_match "Armó el Reparto 2", r2.events.first.summary
    assert_includes r1.siblings, r2
  end

  test "routes are numbered per driver within the date" do
    emilio = create_driver("Emilio")
    c1 = create(@orders.first(2)).route
    e1 = create(@orders[2, 2], driver: emilio).route
    c2 = create(@orders[4, 2]).route
    other_day = DeliveryRoutes::Create.call(date: @date + 1, order_ids: [], user: @admin, driver: @driver).route

    assert_equal ["Chiara · Reparto 1", "Emilio · Reparto 1", "Chiara · Reparto 2"], [c1, e1, c2].map(&:title)
    assert_equal "Reparto 1", other_day.label
    assert_equal 3, DeliveryRoute.where(date: @date).count
  end

  test "an order already in a route cannot be put in a second route of the same driver" do
    create(@orders.first(2))
    assert_no_difference -> { DeliveryRoute.count } do
      result = create([@orders.first, @orders.last])
      assert_not result.ok?
      assert_match "ya está en Chiara · Reparto 1", result.errors.join
    end

    second = create([@orders.last]).route
    assert_not DeliveryRoutes::Editor.new(second, @admin).add_orders([@orders.first.id]).ok?
    assert_equal 1, DeliveryStop.active.where(order_id: @orders.first.id).count
  end

  test "the same form sent twice creates one route" do
    first = create(@orders.first(2), token: "form-123")
    assert_no_difference -> { DeliveryRoute.count } do
      again = create(@orders.first(2), token: "form-123")
      assert again.ok?
      assert again.already
      assert_equal first.route, again.route
    end
    assert_equal 1, DeliveryEvent.where(event_type: "route_created").count
  end

  test "two simultaneous submissions of the same form keep a single route" do
    create([], token: "form-xyz")
    real_find_by = DeliveryRoute.method(:find_by)
    calls = 0
    # La segunda solicitud no ve todavía el recorrido de la primera: choca con el índice único del token.
    result = DeliveryRoute.stub(:find_by, ->(*args, **kwargs) { (calls += 1) == 1 ? nil : real_find_by.call(*args, **kwargs) }) do
      create([], token: "form-xyz")
    end
    assert result.ok?, result.errors.inspect
    assert result.already
    assert_equal 1, DeliveryRoute.where(creation_token: "form-xyz").count
    assert_equal 1, DeliveryRoute.count
  end

  test "stops can be passed between two routes of the same driver, but not completed deliveries" do
    r1 = create(@orders.first(3)).route
    r2 = create(@orders[3, 2]).route
    delivered = r1.active_stops.first
    assert DeliveryRoutes::Deliveries.new(delivered, @driver).deliver.ok?

    moving = r1.active_stops.second
    result = DeliveryRoutes::Editor.new(r1, @admin).transfer(moving, r2)
    assert result.ok?, result.errors.inspect
    assert_equal "Chiara · Reparto 2", moving.reload.removal_reason
    assert_includes r2.active_stops.map(&:order_id), moving.order_id
    assert_match "a Chiara · Reparto 2", r1.events.last.summary
    assert_match "de Chiara · Reparto 1", r2.events.last.summary

    refused = DeliveryRoutes::Editor.new(r1, @admin).transfer(delivered.reload, r2)
    assert_not refused.ok?
    assert_match "ya está entregado", refused.errors.join
    assert_equal r1.id, delivered.reload.delivery_route_id
    assert_nil delivered.removed_at
  end

  test "deliveries and history of one route do not touch the other" do
    r1 = create(@orders.first(2)).route
    r2 = create(@orders[2, 2]).route
    r2_before = r2.stops.reload.map { |s| s.attributes.slice("delivery_status", "delivery_recorded_at", "removed_at", "position") }
    r2_events = r2.events.count

    stop = r1.active_stops.first
    assert DeliveryRoutes::Deliveries.new(stop, @driver).deliver.ok?
    assert DeliveryRoutes::Deliveries.new(r1.active_stops.second, @driver).not_delivered("Estaba cerrado").ok?

    assert_equal r2_before, r2.stops.reload.map { |s| s.attributes.slice("delivery_status", "delivery_recorded_at", "removed_at", "position") }
    assert_equal r2_events, r2.events.count
    assert_equal %w[delivered not_delivered], r1.active_stops.map(&:delivery_status)
    assert DeliveryEvent.where(event_type: %w[stop_delivered stop_not_delivered]).all? { |e| e.delivery_route_id == r1.id }
  end

  test "reassigning a route to a driver who already has one that day is allowed" do
    emilio = create_driver("Emilio")
    create(@orders.first(2))
    emilio_route = create(@orders[2, 2], driver: emilio).route
    assert DeliveryRoutes::Editor.new(emilio_route, @admin).assign_driver(@driver).ok?
    assert_equal ["Chiara · Reparto 1", "Chiara · Reparto 2"], DeliveryRoute.where(date: @date).order(:id).map { |r| r.reload.title }
  end

  test "creating several routes never touches orders, payments, accounts, stock or expenses" do
    snapshot = -> { [Order.order(:id).pluck(:status, :payment_status, :amount_paid_cents, :total_cents, :updated_at), Payment.count, CustomerPayment.count, StockMovement.count, Expense.count] }
    before = snapshot.call
    create(@orders.first(6), token: "a")
    create(@orders.last(4), token: "b")
    create(@orders.last(4), token: "b")
    assert_equal before, snapshot.call
  end
end
