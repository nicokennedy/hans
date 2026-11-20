require "test_helper"
require_relative "../../support/delivery_route_helpers"

# R4: gastos del recorrido, rendición independiente por recorrido, cierre y diferencias de caja.
class DeliveryRoutes::SettlementsTest < ActiveSupport::TestCase
  include DeliveryRouteHelpers

  setup do
    setup_delivery_data
    @category = ExpenseCategory.find_or_create_by!(name: "Logística y envíos")
    @emilio = create_driver("Emilio")
    @orders = Array.new(3) { |i| create_order(create_customer("Cliente #{i}", address: "Calle #{i}")) }
    @r1 = DeliveryRoutes::Create.call(date: @date, order_ids: [@orders[0].id], user: @admin, driver: @driver).route
    @r2 = DeliveryRoutes::Create.call(date: @date, order_ids: [@orders[1].id], user: @admin, driver: @driver).route
    @e1 = DeliveryRoutes::Create.call(date: @date, order_ids: [@orders[2].id], user: @admin, driver: @emilio).route
  end

  def expenses(route, user = @driver)
    DeliveryRoutes::Expenses.new(route, user)
  end

  def spend(route, cents, user: @driver, token: SecureRandom.uuid, **opts)
    expenses(route, user).record(concept: "Nafta", amount_cents: cents, request_token: token, **opts)
  end

  test "each route has its own settlement, also two routes of the same driver the same day" do
    collect(@r1, @r1.active_stops.first, 200_000)
    collect(@r2, @r2.active_stops.first, 150_000)
    collect(@e1, @e1.active_stops.first, 100_000, user: @emilio)
    spend(@r1, 20_000)

    assert_equal [200_000, 20_000, 180_000], summary_of(@r1)
    assert_equal [150_000, 0, 150_000], summary_of(@r2)
    assert_equal [100_000, 0, 100_000], summary_of(@e1)

    assert DeliveryRoutes::Settlements.new(@r1, @driver).submit.ok?
    assert @r1.reload.submitted?
    assert @r2.reload.open_for_driver?, "enviar el Reparto 1 no cierra el Reparto 2"
    assert collect(@r2, @r2.active_stops.first, 50_000).ok?
  end

  test "the driver cannot spend more than the cash of the route; admin can as an explicit exception" do
    collect(@r1, @r1.active_stops.first, 30_000)
    result = spend(@r1, 40_000)
    assert_not result.ok?
    assert_equal ["Supera lo que cobraste ($300). Avisale a administración."], result.errors

    assert spend(@r1, 30_000).ok?
    assert_not spend(@r1, 1).ok?

    assert_not spend(@r1, 10_000, user: @admin).ok?
    assert_not spend(@r1, 10_000, user: @admin, exception: true).ok?
    exception = spend(@r1, 10_000, user: @admin, exception: true, exception_reason: "Peaje autorizado por teléfono")
    assert exception.ok?, exception.errors.inspect
    assert exception.expense.admin_exception?

    summary = DeliveryRoutes::Settlement.new(@r1)
    assert_equal [0, 10_000], [summary.to_deliver_cents, summary.unresolved_cents]
  end

  test "expenses are idempotent and corrections keep the history" do
    collect(@r1, @r1.active_stops.first, 100_000)
    token = SecureRandom.uuid
    first = spend(@r1, 20_000, token: token)
    again = spend(@r1, 20_000, token: token)
    assert again.already
    assert_equal 1, DeliveryExpense.count

    fixed = expenses(@r1).correct(first.expense, concept: "Nafta", amount_cents: 15_000, reason: "Era menos", request_token: SecureRandom.uuid)
    assert fixed.ok?, fixed.errors.inspect
    assert first.expense.reload.voided?
    assert_equal [first.expense, 15_000], [fixed.expense.replaces, fixed.expense.amount_cents]
    assert_equal 15_000, DeliveryRoutes::Settlement.new(@r1).expenses_cents
    assert_raises(ActiveRecord::ReadOnlyRecord) { first.expense.update!(amount_cents: 1) }
    assert_equal "expense_corrected", @r1.events.last.event_type
  end

  test "submitting freezes totals once and blocks the driver; only the driver of the route can submit" do
    collect(@r1, @r1.active_stops.first, 200_000)
    spend(@r1, 20_000)
    assert_not DeliveryRoutes::Settlements.new(@r1, @emilio).submit.ok?
    assert_not DeliveryRoutes::Settlements.new(@r1, @admin).submit.ok?

    first = DeliveryRoutes::Settlements.new(@r1, @driver).submit
    second = DeliveryRoutes::Settlements.new(@r1, @driver).submit
    assert first.ok? && second.ok? && second.already
    @r1.reload
    assert_equal [200_000, 20_000, 180_000], [@r1.collected_cents, @r1.expenses_cents, @r1.expected_cash_cents]
    assert @r1.submitted_at.present?
    assert_equal 1, @r1.events.where(event_type: "settlement_submitted").count
    assert_not spend(@r1, 1_000).ok?
  end

  test "confirming: counted cash, cash difference with a reason (never an expense), expenses posted once" do
    collect(@r1, @r1.active_stops.first, 200_000)
    spend(@r1, 20_000)
    DeliveryRoutes::Settlements.new(@r1, @driver).submit

    assert_not DeliveryRoutes::Settlements.new(@r1, @driver).confirm(counted_cents: 180_000).ok?
    missing_note = DeliveryRoutes::Settlements.new(@r1, @admin).confirm(counted_cents: 170_000)
    assert_not missing_note.ok?
    assert_match "diferencia de caja", missing_note.errors.join

    assert_difference -> { Expense.count } => 1, -> { OutgoingPayment.count } => 1 do
      result = DeliveryRoutes::Settlements.new(@r1, @admin).confirm(counted_cents: 170_000, note: "Faltaron $100", categories: {})
      assert result.ok?, result.errors.inspect
    end
    @r1.reload
    assert @r1.confirmed?
    assert_equal [170_000, -10_000, 0, @admin], [@r1.counted_cash_cents, @r1.difference_cents, @r1.unresolved_cents, @r1.confirmed_by]
    expense = @r1.expenses.first.expense
    assert_equal [@category, 20_000], [expense.expense_category, expense.obligation.amount_cents]
    assert_equal "cash", OutgoingPayment.last.payment_method

    assert_no_difference -> { Expense.count } do
      again = DeliveryRoutes::Settlements.new(@r1, @admin).confirm(counted_cents: 170_000, note: "otra vez")
      assert again.already
    end
    assert_not collections_for(@r1, @admin).record(stop: @r1.active_stops.first, amount_cents: 1_000, request_token: SecureRandom.uuid).ok?
  end

  test "a collection voided from the customer account after the close keeps the confirmed totals and is flagged" do
    collection = collect(@r1, @r1.active_stops.first, 200_000).collection
    DeliveryRoutes::Settlements.new(@r1, @driver).submit
    DeliveryRoutes::Settlements.new(@r1, @admin).confirm(counted_cents: 200_000)

    assert CustomerAccounts::VoidPayment.call(customer_payment: collection.customer_payment, user: @admin, reason: "Era de otro cliente").ok?
    @r1.reload
    assert_equal [200_000, 200_000], [@r1.collected_cents, @r1.counted_cash_cents]
    assert_equal [collection], DeliveryRoutes::Settlement.new(@r1).voided_outside_collections
  end

  test "unresolved amount when expenses exceed collections is not delivered cash and needs a note" do
    collect(@r1, @r1.active_stops.first, 10_000)
    spend(@r1, 30_000, user: @admin, exception: true, exception_reason: "Gomería")
    DeliveryRoutes::Settlements.new(@r1, @driver).submit
    assert_not DeliveryRoutes::Settlements.new(@r1, @admin).confirm(counted_cents: 0).ok?
    assert DeliveryRoutes::Settlements.new(@r1, @admin).confirm(counted_cents: 0, note: "Se resuelve con Chiara").ok?
    @r1.reload
    assert_equal [-20_000, 0, 20_000], [@r1.expected_cash_cents, @r1.difference_cents, @r1.unresolved_cents]
    assert_equal 1, Expense.count, "no se crean gastos ni reintegros para compensar"
  end

  test "money in reports is counted once and orders of other customers, stock and individual payments do not change" do
    before_others = @orders[1..].map { |o| o.reload.attributes.slice("amount_paid_cents", "payment_status", "status") }
    stock = StockMovement.count
    individual = Payment.individual.count
    collect(@r1, @r1.active_stops.first, 200_000)
    collect(@r1, @r1.active_stops.first, 50_000, allocations: {}, unidentified: true)
    spend(@r1, 10_000)
    DeliveryRoutes::Settlements.new(@r1, @driver).submit
    DeliveryRoutes::Settlements.new(@r1, @admin).confirm(counted_cents: 240_000)

    assert_equal 250_000, CustomerPayment.active.where(paid_on: Date.current).sum(:amount_cents)
    assert_equal individual, Payment.individual.count, "las aplicaciones no son ingresos aparte"
    assert_equal stock, StockMovement.count
    assert_equal before_others, @orders[1..].map { |o| o.reload.attributes.slice("amount_paid_cents", "payment_status", "status") }
  end

  private

  def summary_of(route)
    summary = DeliveryRoutes::Settlement.new(route)
    [summary.collected_cents, summary.expenses_cents, summary.to_deliver_cents]
  end
end
