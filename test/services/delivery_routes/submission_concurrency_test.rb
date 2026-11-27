require "test_helper"
require "timeout"
require_relative "../../support/delivery_route_helpers"

class DeliveryRoutes::SubmissionConcurrencyTest < ActiveSupport::TestCase
  include DeliveryRouteHelpers

  self.use_transactional_tests = false

  test "an in-flight delivery cannot change an order after the route is submitted" do
    setup_delivery_data
    customer = create_customer("Cliente de concurrencia")
    order = create_order(customer, date: Date.current)
    route = DeliveryRoutes::Create.call(date: Date.current, order_ids: [order.id], user: @admin, driver: @driver).route
    stop = route.active_stops.first
    backend = Queue.new
    results = Queue.new

    route.with_lock do
      @worker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          backend << connection.select_value("SELECT pg_backend_pid()").to_i
          results << DeliveryRoutes::Deliveries.new(stop, @driver).deliver
        end
      end
      pid = Timeout.timeout(5) { backend.pop }
      Timeout.timeout(5) do
        until !results.empty? || DeliveryRoute.uncached { DeliveryRoute.connection.select_value("SELECT cardinality(pg_blocking_pids(#{pid}))") }.positive?
          sleep 0.01
        end
      end

      assert DeliveryRoutes::Settlements.new(route, @driver).submit.ok?
    end

    assert @worker.join(5), "La entrega no terminó"
    refute results.pop.ok?
    assert_equal "pending", stop.reload.delivery_status
    refute order.reload.delivered?
  ensure
    @worker&.join(5)
    DeliveryEvent.where(delivery_route: route).delete_all if route
    DeliveryStop.where(delivery_route: route).delete_all if route
    route&.reload&.destroy!
    if order
      OrderEvent.where(order: order).delete_all
      StockMovement.where(order: order).delete_all
      order.order_items.delete_all
      Order.where(id: order.id).delete_all
    end
    customer&.destroy!
    category = @product&.category
    @product&.destroy!
    category&.destroy!
    @driver&.destroy!
    @admin&.destroy!
  end
end
