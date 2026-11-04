require "test_helper"
require_relative "../../support/retail_helpers"

# Etapa 1 de la tienda online: origen y confirmación de los pedidos minoristas. Solo los
# confirmados (RetailOrder.committed) cuentan para producción y stock.
class Retail::ConfirmationTest < ActiveSupport::TestCase
  include RetailHelpers

  setup do
    setup_retail
    n = rand(1_000_000)
    @brownie = Preparation.create!(name: "Brownie Conf #{n}", yield_quantity: 1, yield_unit: "kg")
    @stock_item = StockItem.create!(stock_tracking_started_on: Date.new(2026, 1, 1), stockable: @brownie, active: true, quantity: 100, minimum_quantity: 2)
    @mini.create_product_recipe!(yield_quantity: 1).recipe_components.create!(component: @brownie, quantity: 1, unit: "kg")
    @now = Time.zone.local(2026, 10, 20, 14, 0, 0) # martes 14:00: pasó el corte de las 13
    @past = Date.new(2026, 10, 18)
    @future = Date.new(2026, 10, 27)
  end

  def in_time(&block)
    travel_to(@now, &block)
  end

  def store_order(date: @future, items: nil, token: nil)
    items ||= [product_row(@mini, 12, "500"), manual_row("Box Día de la Madre", 1, "45000")]
    result = Retail::SaveOrder.call(order: RetailOrder.new, attributes: base_attributes(delivery_date: date.iso8601), items: items,
                                    user: nil, source: "store", request_token: token)
    raise "no se pudo crear: #{result.errors.inspect}" unless result.ok?

    result.record
  end

  def confirm!(order)
    result = Retail::ChangeConfirmation.call(order: order, action: "confirm", user: @admin)
    assert result.ok?, result.errors.inspect
    order.reload
  end

  def dispatched(order)
    StockMovement.dispatch.where(stock_item: @stock_item, retail_order: order).sum(:quantity)
  end

  def sheet_quantity(date)
    ProductionDaySheet.for(date).rows.find { |row| row[:product_id] == @mini.id }&.dig(:total).to_i
  end

  # --- Altas -----------------------------------------------------------------------------

  test "a manual order created by the team is confirmed automatically, with date and user" do
    order = in_time { create_retail(attributes: { delivery_date: @future.iso8601 }) }

    assert order.source_manual?
    assert order.confirmation_confirmed?
    assert_equal @admin, order.confirmed_by
    assert_equal @now, order.confirmed_at
    assert order.committed?
    assert_equal 32, order.public_token.length
  end

  test "a store order is created awaiting confirmation and does not count" do
    order = in_time { store_order }

    assert order.source_store?
    assert order.confirmation_awaiting?
    assert_nil order.confirmed_at
    assert_not order.committed?
    assert_not_includes RetailOrder.committed, order
    assert_includes RetailOrder.awaiting_review, order
  end

  test "a store order can never be created already confirmed" do
    order = RetailOrder.new(buyer_name: "Bot", delivery_date: @future, source: "store", confirmation_status: "confirmed")

    assert_not order.valid?
    assert_includes order.errors[:confirmation_status].join, "Pendiente de confirmación"
  end

  test "an order created outside SaveOrder (as historical ones) is manual, confirmed and counts" do
    order = RetailOrder.create!(buyer_name: "Histórico", delivery_date: @future)

    assert order.source_manual?
    assert order.confirmation_confirmed?
    assert order.confirmed_at.present?
    assert_includes RetailOrder.committed, order
  end

  test "the database rejects invalid confirmation values" do
    order = create_retail

    assert_raises(ActiveRecord::StatementInvalid) { order.update_columns(confirmation_status: "maybe") }
  end

  # --- Producción ------------------------------------------------------------------------

  test "awaiting orders do not add to the production sheet, but are listed apart" do
    in_time do
      create_retail(attributes: { delivery_date: @future.iso8601 }, items: [product_row(@mini, 3, "500")])
      pending = store_order

      sheet = ProductionDaySheet.for(@future)
      assert_equal 3, sheet_quantity(@future), "solo el pedido manual confirmado"
      assert_empty sheet.special_items, "el box del pedido web no aparece como especial"
      assert_equal [pending], sheet.awaiting_orders
      assert_equal 1, ProductionDaySheet.day_summary(@future)[:orders_count]
    end
  end

  test "a date with only awaiting orders is not a production date" do
    in_time { store_order(date: @past) }

    assert_empty ProductionDaySheet.dates_with_orders(from: @past, to: @past)
    assert ProductionDaySheet.for(@past).empty?
  end

  # --- Stock -----------------------------------------------------------------------------

  test "awaiting orders reserve no stock and never dispatch, even when due" do
    in_time do
      future = store_order(date: @future)
      due = store_order(date: @past)
      Stock::DispatchReconciler.reconcile_due!

      snapshot = Stock::Availability.for_item(@stock_item)
      assert_equal BigDecimal("0"), snapshot.future_committed
      assert_equal BigDecimal("100"), snapshot.available_quantity
      assert_equal BigDecimal("100"), @stock_item.reload.quantity
      assert_equal 0, dispatched(future)
      assert_equal 0, dispatched(due)
    end
  end

  # --- Confirmar -------------------------------------------------------------------------

  test "confirming adds the order to production and stock automatically, without duplicates" do
    in_time do
      future = store_order(date: @future)
      due = store_order(date: @past)

      confirm!(future)
      confirm!(due)

      assert_equal 12, sheet_quantity(@future)
      assert_equal ["Box Día de la Madre"], ProductionDaySheet.for(@future).special_items.map(&:description)
      assert_empty ProductionDaySheet.for(@future).awaiting_orders
      assert_equal BigDecimal("12"), Stock::Availability.for_item(@stock_item).future_committed
      assert_equal BigDecimal("-12"), dispatched(due), "el vencido descuenta al confirmarse"
      assert_equal BigDecimal("88"), @stock_item.reload.quantity

      Stock::DispatchReconciler.reconcile_due!
      Stock::DispatchReconciler.call(due)
      assert_equal BigDecimal("-12"), dispatched(due), "conciliar de nuevo no duplica"
      assert_equal @admin, due.confirmed_by
      assert_equal [%w[awaiting confirmed]], due.retail_order_confirmation_changes.map { |c| [c.from_status, c.to_status] }
    end
  end

  test "confirming twice is refused and changes nothing" do
    in_time do
      order = store_order(date: @past)
      confirm!(order)

      again = Retail::ChangeConfirmation.call(order: order, action: "confirm", user: @admin)
      assert_not again.ok?
      assert_equal ["El pedido ya está confirmado."], again.errors
      assert_equal BigDecimal("-12"), dispatched(order)
      assert_equal 1, order.retail_order_confirmation_changes.count
    end
  end

  test "a canceled awaiting order cannot be confirmed" do
    order = in_time { store_order }
    Retail::ChangeStatus.call(order: order, to_status: "canceled", user: @admin)

    result = Retail::ChangeConfirmation.call(order: order, action: "confirm", user: @admin)
    assert_not result.ok?
    assert order.reload.confirmation_awaiting?
  end

  # --- Rechazar --------------------------------------------------------------------------

  test "rejecting requires a reason, keeps the order out for good and keeps its history" do
    in_time do
      order = store_order(date: @past)

      assert_equal ["Indicá el motivo del rechazo."], Retail::ChangeConfirmation.call(order: order, action: "reject", user: @admin, reason: " ").errors

      result = Retail::ChangeConfirmation.call(order: order, action: "reject", user: @admin, reason: "Sin cupo para esa fecha")
      assert result.ok?
      order.reload
      assert order.confirmation_rejected?
      assert_equal "Sin cupo para esa fecha", order.rejection_reason
      assert_equal @admin, order.rejected_by
      assert order.rejected_at.present?

      Stock::DispatchReconciler.reconcile_due!
      assert_equal 0, dispatched(order)
      assert ProductionDaySheet.for(@past).empty?
      assert_empty ProductionDaySheet.for(@past).awaiting_orders

      assert_not Retail::ChangeConfirmation.call(order: order, action: "confirm", user: @admin).ok?, "un rechazado no vuelve a producción"
      assert order.reload.confirmation_rejected?
      assert_equal [%w[awaiting rejected]], order.retail_order_confirmation_changes.map { |c| [c.from_status, c.to_status] }
    end
  end

  test "an unconfirmed order cannot move through the operational circuit, only be canceled" do
    order = in_time { store_order }

    result = Retail::ChangeStatus.call(order: order, to_status: "in_preparation", user: @admin)
    assert_not result.ok?
    assert_match "confirmalo antes", result.errors.join
    assert order.reload.pending?

    assert Retail::ChangeStatus.call(order: order, to_status: "canceled", user: @admin).ok?
  end

  test "editing a store order keeps its origin and confirmation" do
    in_time do
      order = store_order
      result = Retail::SaveOrder.call(order: order, attributes: base_attributes(delivery_date: @future.iso8601, notes: "Sin nueces"),
                                      items: [product_row(@mini, 2, "500")], user: @admin)
      assert result.ok?
      order.reload
      assert order.source_store?
      assert order.confirmation_awaiting?
      assert_equal 0, sheet_quantity(@future)
    end
  end

  # --- Idempotencia ----------------------------------------------------------------------

  test "the same request token never creates a second order" do
    in_time do
      first = store_order(token: "checkout-123")

      assert_no_difference -> { RetailOrder.count } do
        result = Retail::SaveOrder.call(order: RetailOrder.new, attributes: base_attributes(delivery_date: @future.iso8601),
                                        items: [product_row(@mini, 1, "500")], user: nil, source: "store", request_token: "checkout-123")
        assert result.ok?
        assert result.duplicate?
        assert_equal first, result.record
      end
    end
  end

  test "a concurrent submit with the same token returns the winner's order (unique index)" do
    in_time do
      first = store_order(token: "checkout-race")
      # El primer chequeo no lo ve (como si el otro envío todavía no hubiera hecho commit): el
      # INSERT choca con el índice único y el servicio devuelve el pedido ganador.
      lookups = 0
      RetailOrder.singleton_class.alias_method(:__real_find_by, :find_by)
      RetailOrder.define_singleton_method(:find_by) { |*args, **kw| (lookups += 1) == 1 ? nil : __real_find_by(*args, **kw) }
      begin
        result = Retail::SaveOrder.call(order: RetailOrder.new, attributes: base_attributes(delivery_date: @future.iso8601),
                                        items: [product_row(@mini, 1, "500")], user: nil, source: "store", request_token: "checkout-race")
      ensure
        RetailOrder.singleton_class.send(:remove_method, :find_by)
        RetailOrder.singleton_class.send(:remove_method, :__real_find_by)
      end
      assert result.ok?, result.errors.inspect
      assert result.duplicate?
      assert_equal first, result.record
      assert_equal 1, RetailOrder.where(request_token: "checkout-race").count
    end
  end

  test "an unknown source is refused" do
    result = Retail::SaveOrder.call(order: RetailOrder.new, attributes: base_attributes, items: [product_row(@mini, 1, "500")], user: @admin, source: "api")

    assert_not result.ok?
    assert_equal ["El origen del pedido no es válido."], result.errors
  end

  # --- Mayoristas ------------------------------------------------------------------------

  test "wholesale orders keep dispatching and counting next to an awaiting retail order" do
    in_time do
      store_order(date: @past)
      wholesale = Order.new(customer: @customer, delivery_date: @past, created_by_admin: true, payment_method_selected: "cash_on_delivery")
      wholesale.order_items.build(product: @mini, quantity: 4)
      wholesale.save!

      Stock::DispatchReconciler.reconcile_due!
      assert_equal BigDecimal("-4"), StockMovement.dispatch.where(stock_item: @stock_item, order: wholesale).sum(:quantity)
      assert_equal 4, sheet_quantity(@past)
    end
  end
end
