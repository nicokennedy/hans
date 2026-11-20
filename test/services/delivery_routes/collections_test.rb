require "test_helper"
require_relative "../../support/delivery_route_helpers"

# R4: cobros en efectivo del repartidor sobre la cuenta corriente existente.
class DeliveryRoutes::CollectionsTest < ActiveSupport::TestCase
  include DeliveryRouteHelpers

  setup do
    setup_delivery_data
    @aurora = create_customer("Café Aurora", address: "Av. Colón 2345")
    @old_order = create_order(@aurora, date: @date - 7)
    @order = create_order(@aurora)
    @other = create_order(create_customer("Bar La Esquina"))
    @route = DeliveryRoutes::Create.call(date: @date, order_ids: [@order.id, @other.id], user: @admin, driver: @driver).route
    @stop = @route.active_stops.find_by(order: @order)
    @other_stop = @route.active_stops.find_by(order: @other)
  end

  test "paid in full: one cash account payment applied to the order, linked to route, stop and driver" do
    stock_before = StockMovement.count
    result = collect(@route, @stop, @order.balance_due_cents, report: "paid_all")
    assert result.ok?, result.errors.inspect

    collection = result.collection
    payment = collection.customer_payment
    assert_equal ["cash_on_delivery", Date.current, @driver, @aurora, 200_000], [payment.payment_method, payment.paid_on, payment.user, payment.customer, payment.amount_cents]
    assert_match "Cobro de reparto: Chiara · Reparto 1", payment.note
    assert_equal [[@order.id, 200_000]], payment.applications.map { |a| [a.order_id, a.amount_cents] }
    assert_equal [@route, @stop, @aurora, "allocated", 0], [collection.delivery_route, collection.delivery_stop, collection.customer, collection.mode, collection.credit_cents]
    assert_equal "paid", @order.reload.payment_status
    assert_equal 0, @order.balance_due_cents
    assert_equal "paid_all", @stop.reload.payment_report
    assert_equal stock_before, StockMovement.count
    assert_equal "collection_recorded", @route.events.last.event_type
    assert_equal 200_000, DeliveryRoutes::Settlement.new(@route).collected_cents
  end

  test "partial payment leaves a balance and asks for the signed receipt photo once delivered" do
    DeliveryRoutes::Deliveries.new(@stop, @driver).deliver
    assert collect(@route, @stop, 50_000, report: "partial").ok?
    assert_equal 150_000, @order.reload.balance_due_cents
    assert_equal "partial", @order.payment_status
    assert @stop.reload.receipt_photo_pending?
  end

  test "not paid: nothing is registered, only the answer, and the photo is required" do
    DeliveryRoutes::Deliveries.new(@stop, @driver).deliver
    assert_no_difference -> { CustomerPayment.count } do
      assert collections_for(@route).report_unpaid(@stop).ok?
    end
    assert_equal "none", @stop.reload.payment_report
    assert @stop.receipt_photo_pending?
    assert_equal 0, DeliveryRoutes::Settlement.new(@route).collected_cents
  end

  test "previous debts: the cash is split among several orders of the same customer and the rest is credit" do
    allocations = { @order.id => 200_000, @old_order.id => 200_000 }
    result = collect(@route, @stop, 450_000, allocations: allocations, report: "other")
    assert result.ok?, result.errors.inspect
    assert_equal 50_000, result.collection.credit_cents
    assert_equal [0, 0], [@order.reload.balance_due_cents, @old_order.reload.balance_due_cents]
    assert_equal 50_000, CustomerAccounts::ApplyCredit.available_cents(@aurora)
    assert_equal 1, CustomerPayment.count
    assert_equal 450_000, DeliveryRoutes::Settlement.new(@route).collected_cents
  end

  test "never applies more than an order's balance nor to another customer's order" do
    assert_no_difference ["CustomerPayment.count", "DeliveryCollection.count"] do
      assert_not collect(@route, @stop, 300_000, allocations: { @order.id => 300_000 }).ok?
      assert_not collect(@route, @stop, 100_000, allocations: { @other.id => 100_000 }).ok?
      assert_not collect(@route, @stop, 100_000, allocations: { @order.id => 150_000 }).ok?
      assert_not collect(@route, @stop, 0).ok?
    end
    assert_equal 200_000, @other.reload.balance_due_cents
  end

  test "unknown order: everything stays as the customer's credit, marked to identify, and admin applies it later" do
    result = collect(@route, @stop, 120_000, allocations: {}, unidentified: true, report: "unidentified")
    assert result.ok?
    collection = result.collection
    assert collection.unidentified?
    assert_equal [120_000, 0], [collection.credit_cents, collection.customer_payment.applications.count]
    assert_equal 200_000, @order.reload.balance_due_cents
    assert_equal [collection], DeliveryRoutes::Settlement.new(@route).unidentified_collections

    applied = CustomerAccounts::ApplyCredit.call(customer: @aurora, user: @admin, allocations: { @order.id => 120_000 })
    assert applied.ok?, applied.errors.inspect
    assert_equal 80_000, @order.reload.balance_due_cents
    assert_equal 120_000, DeliveryRoutes::Settlement.new(@route).collected_cents
  end

  test "double tap or a retry with the same form registers the money once" do
    token = SecureRandom.uuid
    first = collect(@route, @stop, 100_000, token: token)
    second = collect(@route, @stop, 100_000, token: token)
    assert first.ok? && second.ok?
    assert second.already
    assert_equal first.collection, second.collection
    assert_equal [1, 1], [CustomerPayment.count, DeliveryCollection.count]
    assert_equal 100_000, @order.reload.amount_paid_cents
  end

  test "two simultaneous requests with the same form keep a single payment" do
    token = SecureRandom.uuid
    collect(@route, @stop, 100_000, token: token)
    real = DeliveryCollection.method(:find_by)
    calls = 0
    result = DeliveryCollection.stub(:find_by, ->(*a, **k) { (calls += 1) == 1 ? nil : real.call(*a, **k) }) do
      collect(@route, @stop, 100_000, token: token)
    end
    assert result.ok?, result.errors.inspect
    assert result.already
    assert_equal [1, 1], [CustomerPayment.count, DeliveryCollection.count]
  end

  test "the driver corrects a collection with a reason: the old one is voided and kept, the new one replaces it" do
    old = collect(@route, @stop, 150_000).collection
    assert_not collections_for(@route).correct(old, amount_cents: 100_000, reason: " ", request_token: SecureRandom.uuid).ok?

    result = collections_for(@route).correct(old, amount_cents: 100_000, reason: "Me equivoqué de importe", request_token: SecureRandom.uuid)
    assert result.ok?, result.errors.inspect
    old.reload
    assert old.voided?
    assert_equal ["Me equivoqué de importe", @driver], [old.void_reason, old.voided_by]
    assert old.customer_payment.voided?
    assert_equal old, result.collection.replaces
    assert_equal 100_000, @order.reload.amount_paid_cents
    assert_equal 100_000, DeliveryRoutes::Settlement.new(@route).collected_cents
    event = @route.events.where(event_type: "collection_corrected").last
    assert_equal [150_000, 100_000, @driver], [event.data["before_cents"], event.data["after_cents"], event.user]
    assert_equal 2, CustomerPayment.count, "nada se borra"

    assert_raises(ActiveRecord::ReadOnlyRecord) { old.update!(amount_cents: 1) }
    assert_raises(ActiveRecord::ReadOnlyRecord) { old.destroy }
  end

  test "correcting to zero voids without replacement" do
    old = collect(@route, @stop, 150_000).collection
    result = collections_for(@route).correct(old, amount_cents: 0, reason: "Al final no me pagaron", request_token: SecureRandom.uuid)
    assert result.ok?
    assert_equal 0, @order.reload.amount_paid_cents
    assert_equal 0, DeliveryRoutes::Settlement.new(@route).collected_cents
    assert_equal "collection_voided", @route.events.last.event_type
  end

  test "a correction is refused when the credit was already applied to other orders" do
    old = collect(@route, @stop, 50_000, allocations: {}, unidentified: true).collection
    CustomerAccounts::ApplyCredit.call(customer: @aurora, user: @admin, allocations: { @old_order.id => 50_000 })
    result = collections_for(@route).correct(old, amount_cents: 0, reason: "Error", request_token: SecureRandom.uuid)
    assert_not result.ok?
    assert_match "Avisale a administración", result.errors.join
    assert_not old.reload.voided?
  end

  test "after sending the settlement the driver cannot touch money; admin can until the close is confirmed" do
    collection = collect(@route, @stop, 100_000).collection
    assert DeliveryRoutes::Settlements.new(@route, @driver).submit.ok?

    assert_not collect(@route, @other_stop, 10_000).ok?
    assert_match "Ya enviaste la rendición", collect(@route, @other_stop, 10_000).errors.join
    assert_not collections_for(@route).correct(collection, amount_cents: 50_000, reason: "x", request_token: SecureRandom.uuid).ok?
    assert_not DeliveryRoutes::Deliveries.new(@other_stop, @driver).deliver.ok?

    fixed = collections_for(@route, @admin).correct(collection, amount_cents: 90_000, reason: "Contado en la oficina", request_token: SecureRandom.uuid)
    assert fixed.ok?, fixed.errors.inspect
    assert_equal 90_000, DeliveryRoutes::Settlement.new(@route).collected_cents
  end

  test "another driver cannot register money on a route that is not theirs" do
    emilio = create_driver("Emilio")
    assert_no_difference -> { CustomerPayment.count } do
      result = collect(@route, @stop, 100_000, user: emilio)
      assert_not result.ok?
    end
  end
end
