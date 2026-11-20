require "test_helper"
require_relative "../../support/delivery_route_helpers"

class DeliveryRoutes::RoutesTest < ActiveSupport::TestCase
  include DeliveryRouteHelpers

  setup do
    setup_delivery_data
    @aurora = create_customer("Café Aurora", address: "Av. Colón 2345", city: "Mar del Plata", delivery_instructions: "Timbre verde")
    @esquina = create_customer("Bar La Esquina", address: "Güemes 3120")
    @sin_dir = create_customer("Bistró Verde")
    @o1 = create_order(@aurora)
    @o2 = create_order(@esquina)
    @o3 = create_order(@sin_dir)
    @canceled = create_order(@esquina, status: "canceled")
    @other_day = create_order(@aurora, date: @date + 7)
  end

  def create_route(ids = [@o1.id, @o2.id, @o3.id])
    DeliveryRoutes::Create.call(date: @date, order_ids: ids, user: @admin, driver: @driver)
  end

  def editor(route)
    DeliveryRoutes::Editor.new(route, @admin)
  end

  test "creates a route with the chosen orders and a history entry" do
    result = create_route
    assert result.ok?, result.errors.inspect
    route = result.route
    assert_equal "draft", route.status
    assert_equal [1, 2, 3], route.active_stops.map(&:position)
    assert_equal [@o1, @o2, @o3].map(&:id).sort, route.active_stops.map(&:order_id).sort
    assert_equal "route_created", route.events.first.event_type
  end

  test "canceled orders and orders of another date cannot be added" do
    result = create_route([@o1.id, @canceled.id, @other_day.id])
    assert_not result.ok?
    assert_match "cancelados", result.errors.join

    route = create_route([@o1.id]).route
    assert_not editor(route).add_orders([@canceled.id]).ok?
    assert_not editor(route).add_orders([@other_day.id]).ok?
    assert_equal 1, route.active_stops.count
  end

  test "an order cannot be added twice, to this or another route" do
    route = create_route([@o1.id]).route
    result = editor(route).add_orders([@o1.id])
    assert_not result.ok?
    assert_match "ya está en este recorrido", result.errors.join

    other = DeliveryRoute.create!(date: @date, driver: create_driver("Emilio"), created_by: @admin)
    assert_not editor(other).add_orders([@o1.id]).ok?
    assert_raises(ActiveRecord::RecordNotUnique) do
      other.stops.create!(kind: "order", order: @o1, customer: @aurora, position: 1)
    end
  end

  test "a driver can have several routes per date and every new route needs an active driver" do
    first = create_route([@o1.id])
    second = create_route([@o2.id])
    assert first.ok? && second.ok?, second.errors.inspect
    assert_not_equal first.route, second.route

    assert_not DeliveryRoutes::Create.call(date: @date, order_ids: [@o2.id], user: @admin).ok?
    assert_not DeliveryRoutes::Create.call(date: @date, order_ids: [@o2.id], user: @admin, driver: create_driver("Inactivo", active: false)).ok?
    assert_not DeliveryRoutes::Create.call(date: @date, order_ids: [@o2.id], user: @admin, driver: @admin).ok?
  end

  test "reorders stops and keeps positions contiguous" do
    route = create_route.route
    first, second, third = route.active_stops.map(&:order_id)
    assert editor(route).move(route.active_stops.last, "up").ok?
    assert_equal [first, third, second], route.active_stops.reload.map(&:order_id)
    assert_equal [1, 2, 3], route.active_stops.map(&:position)
    assert_equal "stop_moved", route.events.last.event_type
  end

  test "manual stops with address and instructions can be added and edited" do
    route = create_route([@o1.id]).route
    assert editor(route).add_manual(kind: "supplies_pickup", title: "Buscar harina", address: "Juan B. Justo 4100", notes: "Ya está paga").ok?
    stop = route.active_stops.last
    assert_equal ["Buscar harina", "Juan B. Justo 4100", "Ya está paga", 2], [stop.title, stop.address, stop.notes, stop.position]
    assert_match "google.com/maps", stop.google_maps_url

    assert editor(route).update_manual(stop, title: "Buscar harina y azúcar", address: "Juan B. Justo 4100").ok?
    assert_equal "Buscar harina y azúcar", stop.reload.title
    assert_equal "stop_updated", route.events.last.event_type

    assert_not editor(route).add_manual(kind: "purchase", title: "").ok?
    assert_not editor(route).add_manual(kind: "order", title: "Trampa").ok?
  end

  test "removing a stop keeps the row and the order, and it can be restored" do
    route = create_route.route
    stop = route.active_stops.first
    result = editor(route).remove(stop, removal_kind: "owners_deliver")
    assert result.ok?, result.errors.inspect

    stop.reload
    assert stop.removed?
    assert_equal @admin, stop.removed_by
    assert_equal [1, 2], route.active_stops.map(&:position)
    assert_not_includes route.unassigned_orders, @o1, "un pedido quitado a propósito no figura como sin asignar"
    assert_equal "received", @o1.reload.status

    assert editor(route).restore(stop).ok?
    assert_not stop.reload.removed?
    assert_equal 3, stop.position
  end

  test "removing with 'other' requires a reason" do
    route = create_route.route
    assert_not editor(route).remove(route.active_stops.first, removal_kind: "other").ok?
    assert editor(route).remove(route.active_stops.first, removal_kind: "other", reason: "Cerrado por vacaciones").ok?
  end

  test "unassigned orders lists the day's orders that nobody has" do
    route = create_route([@o1.id]).route
    assert_equal [@esquina, @sin_dir].map(&:name).sort, route.unassigned_orders.map { |o| o.customer.name }.sort
    assert editor(route).add_orders([@o2.id, @o3.id]).ok?
    assert_empty route.unassigned_orders
  end

  test "customers without address are flagged and nothing is invented" do
    route = create_route.route
    stop = route.active_stops.find_by(order: @o3)
    assert stop.missing_address?
    assert_nil stop.google_maps_url
    assert_nil @sin_dir.reload.address

    aurora = route.active_stops.find_by(order: @o1)
    assert_equal "Av. Colón 2345", aurora.address_line
    assert_equal "Timbre verde", aurora.instructions
  end

  test "order stops always show the customer's current address" do
    route = create_route([@o2.id]).route
    @esquina.update!(address: "Güemes 3150")
    assert_equal "Güemes 3150", route.active_stops.first.address_line
  end

  test "warnings when the order is canceled or moved after building the route" do
    route = create_route([@o1.id]).route
    @o1.update_column(:status, "canceled")
    assert_includes route.active_stops.first.order_warnings, "El pedido está cancelado."
  end

  test "suggests the order of the customer's last route" do
    previous = DeliveryRoutes::Create.call(date: @date - 7, order_ids: [], user: @admin, driver: @driver).route
    previous.stops.create!(kind: "order", order: create_order(@sin_dir, date: @date - 7), customer: @sin_dir, position: 1)
    previous.stops.create!(kind: "order", order: create_order(@esquina, date: @date - 7), customer: @esquina, position: 2)

    route = create_route.route
    assert_equal [@sin_dir, @esquina, @aurora].map(&:id), route.active_stops.map(&:customer_id)
  end

  test "building and editing never touches orders, payments, stock or accounts" do
    @o1.payments.create!(amount_cents: 10_000, paid_at: Time.current, payment_method: "cash_on_delivery")
    tracked = -> { [Payment.count, CustomerPayment.count, StockMovement.count, Expense.count, Obligation.count, OrderEvent.count] }
    orders_before = Order.order(:id).pluck(:id, :status, :payment_status, :amount_paid_cents, :total_cents, :delivery_date, :updated_at)
    counts_before = tracked.call

    route = create_route.route
    ed = editor(route)
    ed.move(route.active_stops.last, "up")
    ed.add_manual(kind: "errand", title: "Banco")
    ed.remove(route.active_stops.first, removal_kind: "rescheduled")
    ed.restore(route.removed_stops.first)

    assert_equal orders_before, Order.order(:id).pluck(:id, :status, :payment_status, :amount_paid_cents, :total_cents, :delivery_date, :updated_at)
    assert_equal counts_before, tracked.call
  end

  test "the history cannot be edited or deleted" do
    event = create_route.route.events.first
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.update!(event_type: "stop_moved") }
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.destroy }
  end

  test "routes that are no longer in preparation cannot be edited" do
    route = create_route.route
    route.update_column(:status, "in_progress")
    result = editor(route).add_manual(kind: "errand", title: "Banco")
    assert_not result.ok?
    assert_match "ya no está en preparación", result.errors.join
  end

  test "only active driver users can be assigned, and a route cannot lose its driver" do
    route = create_route.route
    driver = create_driver("Emilio")
    assert_not editor(route).assign_driver(@admin).ok?
    assert_not editor(route).assign_driver(create_driver("Baja", active: false)).ok?
    assert_not editor(route).assign_driver(nil).ok?
    assert editor(route).assign_driver(driver).ok?
    assert_equal driver, route.reload.driver
    assert_equal "driver_assigned", route.events.last.event_type
  end

  test "routes created in R2 without a driver keep working and can get one" do
    legacy = DeliveryRoute.new(date: @date - 3, created_by: @admin)
    legacy.save!(validate: false)
    assert editor(legacy).add_manual(kind: "errand", title: "Banco").ok?
    assert editor(legacy).assign_driver(@driver).ok?
  end
end
