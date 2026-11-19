require "test_helper"
require_relative "../../support/delivery_route_helpers"

class DeliveryRoutes::TransfersTest < ActiveSupport::TestCase
  include DeliveryRouteHelpers

  setup do
    setup_delivery_data
    @emilio = create_driver("Emilio")
    @orders = Array.new(5) { |i| create_order(create_customer("Cliente #{i}", address: "Calle #{i} 100")) }
    @chiara_route = DeliveryRoutes::Create.call(date: @date, order_ids: @orders.first(2).map(&:id), user: @admin, driver: @driver).route
    @emilio_route = DeliveryRoutes::Create.call(date: @date, order_ids: @orders[2, 2].map(&:id), user: @admin, driver: @emilio).route
  end

  test "a date can have several routes, one per driver, and unassigned orders are the rest" do
    assert_equal 2, DeliveryRoute.where(date: @date).count
    assert_equal [@orders.last], DeliveryRoute.unassigned_orders_for(@date).to_a
  end

  test "an order cannot be in two routes at the same time" do
    result = DeliveryRoutes::Editor.new(@emilio_route, @admin).add_orders([@orders.first.id])
    assert_not result.ok?
    assert_match "recorrido del", result.errors.join
  end

  test "transferring moves the order to the other driver and records it on both routes" do
    stop = @chiara_route.active_stops.first
    order = stop.order
    order_before = order.attributes.slice("status", "payment_status", "amount_paid_cents", "total_cents", "updated_at")

    result = DeliveryRoutes::Editor.new(@chiara_route, @admin).transfer(stop, @emilio_route)
    assert result.ok?, result.errors.inspect

    assert_equal "transferred", stop.reload.removal_kind
    assert_equal 1, @chiara_route.active_stops.count
    assert_equal [1], @chiara_route.active_stops.map(&:position)
    moved = @emilio_route.active_stops.last
    assert_equal [order.id, 3, "pending"], [moved.order_id, moved.position, moved.delivery_status]
    assert_equal "stop_transferred_out", @chiara_route.events.last.event_type
    assert_equal "stop_transferred_in", @emilio_route.events.last.event_type
    assert_equal @admin, @emilio_route.events.last.user
    assert_equal order_before, order.reload.attributes.slice("status", "payment_status", "amount_paid_cents", "total_cents", "updated_at")
    assert_not_includes DeliveryRoute.unassigned_orders_for(@date), order
  end

  test "a not delivered stop can be passed to another driver for a new attempt" do
    stop = @chiara_route.active_stops.first
    DeliveryRoutes::Deliveries.new(stop, @driver).not_delivered("Estaba cerrado")
    assert DeliveryRoutes::Editor.new(@chiara_route, @admin).transfer(stop, @emilio_route).ok?
    assert_equal "pending", @emilio_route.active_stops.last.delivery_status
  end

  test "only to another route of the same date, and only order stops" do
    editor = DeliveryRoutes::Editor.new(@chiara_route, @admin)
    stop = @chiara_route.active_stops.first
    other_day = DeliveryRoutes::Create.call(date: @date + 7, order_ids: [], user: @admin, driver: @emilio).route
    assert_not editor.transfer(stop, other_day).ok?
    assert_not editor.transfer(stop, @chiara_route).ok?
    assert_not editor.transfer(stop, nil).ok?
    editor.add_manual(kind: "errand", title: "Banco")
    assert_not editor.transfer(@chiara_route.active_stops.last, @emilio_route).ok?
  end

  test "a transferred stop cannot be restored into the old route" do
    stop = @chiara_route.active_stops.first
    DeliveryRoutes::Editor.new(@chiara_route, @admin).transfer(stop, @emilio_route)
    assert_not DeliveryRoutes::Editor.new(@chiara_route, @admin).restore(stop).ok?
  end
end
