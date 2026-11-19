require "test_helper"
require_relative "../../support/delivery_route_helpers"

class DeliveryRoutes::DeliveriesTest < ActiveSupport::TestCase
  include DeliveryRouteHelpers

  setup do
    setup_delivery_data
    @aurora = create_customer("Café Aurora", address: "Av. Colón 2345")
    @esquina = create_customer("Bar La Esquina", address: "Güemes 3120")
    @o1 = create_order(@aurora)
    @o2 = create_order(@esquina)
    @o1.payments.create!(amount_cents: 50_000, paid_at: Time.current, payment_method: "cash_on_delivery")
    @route = DeliveryRoutes::Create.call(date: @date, order_ids: [@o1.id, @o2.id], user: @admin, driver: @driver).route
    @stop = @route.active_stops.find_by(order: @o1)
  end

  def deliveries(stop = @stop, user = @driver)
    DeliveryRoutes::Deliveries.new(stop, user)
  end

  def money_snapshot
    [Payment.count, CustomerPayment.count, StockMovement.count, Expense.count, Obligation.count,
     Order.order(:id).pluck(:total_cents, :amount_paid_cents, :payment_status)]
  end

  test "delivering marks the order as Entregado and records who and when, without touching money or stock" do
    before = money_snapshot
    result = deliveries.deliver
    assert result.ok?, result.errors.inspect
    assert_not result.already

    @stop.reload
    assert_equal "delivered", @stop.delivery_status
    assert_equal @driver, @stop.delivery_recorded_by
    assert_in_delta Time.current, @stop.delivery_recorded_at, 5
    assert_equal "delivered", @o1.reload.status
    assert_equal "partial", @o1.payment_status
    assert_equal before, money_snapshot

    order_event = OrderEvent.where(order: @o1).last
    assert_equal ["status", "received", "delivered", @driver], [order_event.field_name, order_event.old_value, order_event.new_value, order_event.user]
    assert_equal "stop_delivered", @route.events.last.event_type
  end

  test "a double tap or a retry does not duplicate anything" do
    assert deliveries.deliver.ok?
    second = deliveries.deliver
    assert second.ok?
    assert second.already
    assert_equal 1, OrderEvent.where(order: @o1).count
    assert_equal 1, @route.events.where(event_type: "stop_delivered").count
  end

  test "a canceled order cannot be delivered" do
    @o1.update_column(:status, "canceled")
    result = deliveries.deliver
    assert_not result.ok?
    assert_match "cancelado", result.errors.join
    assert_equal "pending", @stop.reload.delivery_status
    assert_equal "canceled", @o1.reload.status
  end

  test "a removed or transferred stop cannot be recorded" do
    DeliveryRoutes::Editor.new(@route, @admin).remove(@stop, removal_kind: "owners_deliver")
    result = deliveries.deliver
    assert_not result.ok?
    assert_match "ya no está en tu recorrido", result.errors.join
    assert_equal "received", @o1.reload.status
  end

  test "not delivered keeps the order as it was, with the reason" do
    result = deliveries.not_delivered("Estaba cerrado")
    assert result.ok?
    @stop.reload
    assert_equal ["not_delivered", "Estaba cerrado"], [@stop.delivery_status, @stop.not_delivered_reason]
    assert_equal "received", @o1.reload.status
    assert_equal "stop_not_delivered", @route.events.last.event_type

    assert deliveries.not_delivered("Estaba cerrado").already
    assert_equal 1, @route.events.where(event_type: "stop_not_delivered").count
    assert_not deliveries.not_delivered("Inventado").ok?
  end

  test "a not delivered stop can still be delivered later, but a delivered one cannot go back" do
    deliveries.not_delivered("No llegué")
    assert deliveries.deliver.ok?
    assert_equal "delivered", @stop.reload.delivery_status
    assert_nil @stop.not_delivered_reason

    result = deliveries.not_delivered("Estaba cerrado")
    assert_not result.ok?
    assert_equal "delivered", @stop.reload.delivery_status
  end

  test "manual stops are marked as done, never as delivered" do
    DeliveryRoutes::Editor.new(@route, @admin).add_manual(kind: "supplies_pickup", title: "Buscar harina")
    manual = @route.active_stops.find_by(kind: "supplies_pickup")
    assert_not deliveries(manual).deliver.ok?
    assert deliveries(manual).done.ok?
    assert deliveries(manual).done.already
    assert_equal "done", manual.reload.delivery_status
  end

  test "completed stops cannot be removed or transferred, but can be reordered" do
    emilio_route = DeliveryRoutes::Create.call(date: @date, order_ids: [], user: @admin, driver: create_driver("Emilio")).route
    deliveries.deliver
    editor = DeliveryRoutes::Editor.new(@route, @admin)
    assert_not editor.remove(@stop, removal_kind: "owners_deliver").ok?
    assert_not editor.transfer(@stop, emilio_route).ok?
    assert editor.move(@stop, "down").ok?
    assert_not @stop.reload.removed?
  end
end
