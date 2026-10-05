require "test_helper"

# El conteo físico (y la producción) concilian primero las salidas vencidas
# pendientes. Así un conteo post-reparto no se vuelve a descontar después.
class Stock::CountReconciliationTest < ActiveSupport::TestCase
  DAY = 6 # 2026-10-06

  def setup
    @category = Category.create!(name: "CountRecCat#{rand(1_000_000)}", position: 1, active: true)
    @customer = Customer.create!(name: "Cliente CountRec #{rand(1_000_000)}", active: true)
    @user = User.create!(email: "countrec-#{rand(1_000_000)}@example.com", password: "password123", role: "admin")
    @product = Product.create!(name: "Producto CountRec #{rand(1_000_000)}", category: @category, price_cents: 500, cost_cents: 200, active: true, position: 1)
    @item = StockItem.create!(stockable: @product, active: true, quantity: 20, minimum_quantity: 5, stock_tracking_started_on: Date.new(2026, 1, 1))
  end

  def at(hour, min = 0, &block)
    travel_to(Time.zone.local(2026, 10, DAY, hour, min, 0), &block)
  end

  def todays_order(quantity: 5, product: @product)
    order = nil
    at(9) do
      order = Order.new(customer: @customer, delivery_date: Date.new(2026, 10, DAY), created_by_admin: true, payment_method_selected: "cash_on_delivery")
      order.order_items.build(product: product, quantity: quantity)
      order.save!
    end
    order
  end

  def kinds
    StockMovement.order(:id).map { |m| [ m.movement_type, m.quantity.to_i ] }
  end

  # A
  test "pedido de hoy + después de las 13:00 + conteo: primero se materializa la salida y el conteo deja exactamente el físico contado" do
    order = todays_order(quantity: 5)

    at(14) do
      assert_equal 0, StockMovement.count # nadie abrió el panel: la salida sigue sin materializar

      Stock::RegisterAdjustment.call(stock_item: @item, counted_quantity: 12, user: @user)

      assert_equal BigDecimal(12), @item.reload.quantity
      assert_equal [ [ "dispatch", -5 ], [ "adjustment", -3 ] ], kinds # 20 -5 = 15, y el conteo lo corrige a 12
      assert_equal order.id, StockMovement.dispatch.last.order_id
    end
  end

  # B
  test "volver a abrir Stock después del conteo no vuelve a descontar el pedido" do
    todays_order(quantity: 5)

    at(14) do
      Stock::RegisterAdjustment.call(stock_item: @item, counted_quantity: 12, user: @user)

      snapshot = Stock::Availability.for_item(@item)

      assert_equal BigDecimal(12), @item.reload.quantity
      assert_equal BigDecimal(12), snapshot.physical_quantity
      assert_equal BigDecimal(12), snapshot.available_quantity
      assert_equal 2, StockMovement.count
    end
  end

  # C
  test "dos conciliaciones (o más) no duplican la salida" do
    order = todays_order(quantity: 5)

    at(14) do
      Stock::RegisterAdjustment.call(stock_item: @item, counted_quantity: 12, user: @user)
      2.times { Stock::DispatchReconciler.reconcile_due! }
      Stock::DispatchReconciler.call(order)

      assert_equal 1, StockMovement.dispatch.where(order: order).count
      assert_equal BigDecimal(12), @item.reload.quantity
    end
  end

  # D
  test "conteo antes de las 13:00: respeta la lógica de salidas de hoy (siguen pendientes y se restan del disponible)" do
    todays_order(quantity: 5)

    at(12) do
      Stock::RegisterAdjustment.call(stock_item: @item, counted_quantity: 12, user: @user)

      assert_equal [ [ "adjustment", -8 ] ], kinds # sin salida materializada todavía
      snapshot = Stock::Availability.for_item(@item)
      assert_equal BigDecimal(12), snapshot.physical_quantity
      assert_equal BigDecimal(5), snapshot.today_dispatch
      assert_not snapshot.today_dispatch_materialized
      assert_equal BigDecimal(7), snapshot.available_quantity
    end
  end

  # E
  test "producción después de las 13:00 con salida pendiente: primero concilia y después suma la producción" do
    todays_order(quantity: 5)

    at(14) do
      Stock::RegisterProduction.call(stock_item: @item, quantity: 10, user: @user)

      assert_equal [ [ "dispatch", -5 ], [ "production", 10 ] ], kinds
      assert_equal BigDecimal(25), @item.reload.quantity # 20 - 5 + 10
      assert_equal BigDecimal(25), StockMovement.production.last.resulting_quantity
    end
  end

  # F
  test "conteo absoluto: sea cual sea el físico previo, queda exactamente el número ingresado" do
    todays_order(quantity: 5)

    at(14) do
      [ [ 50, 12 ], [ 3, 12 ], [ 12, 12 ], [ 12, 0 ], [ 0, 31 ] ].each do |previous, counted|
        @item.update_columns(quantity: previous) if previous != 12 # fuerza un físico previo arbitrario (también negativo/mayor)
        Stock::RegisterAdjustment.call(stock_item: @item, counted_quantity: counted, user: @user)

        assert_equal BigDecimal(counted), @item.reload.quantity, "previo #{previous}, contado #{counted}"
      end

      @item.update_columns(quantity: -40)
      Stock::RegisterAdjustment.call(stock_item: @item, counted_quantity: 9, user: @user)
      assert_equal BigDecimal(9), @item.reload.quantity
      assert_equal 1, StockMovement.dispatch.count # la salida de hoy se materializó una sola vez en toda la secuencia
    end
  end

  # --- alcance acotado ---------------------------------------------------

  test "los compromisos futuros no cambian: contar o producir no mueve pedidos a futuro" do
    at(14) do
      future = Order.new(customer: @customer, delivery_date: Date.new(2026, 10, 9), created_by_admin: true, payment_method_selected: "cash_on_delivery")
      future.order_items.build(product: @product, quantity: 7)
      future.save!

      Stock::RegisterAdjustment.call(stock_item: @item, counted_quantity: 15, user: @user)
      Stock::RegisterProduction.call(stock_item: @item, quantity: 3, user: @user)

      assert_equal BigDecimal(7), Stock::Availability.for_item(@item).future_committed
      assert_equal 0, StockMovement.dispatch.count
    end
  end

  test "la cantidad inválida se rechaza sin conciliar ni escribir nada" do
    todays_order(quantity: 5)

    at(14) do
      assert_raises(Stock::RegisterAdjustment::InvalidQuantityError) { Stock::RegisterAdjustment.call(stock_item: @item, counted_quantity: -1, user: @user) }
      assert_raises(Stock::RegisterProduction::InvalidQuantityError) { Stock::RegisterProduction.call(stock_item: @item, quantity: 0, user: @user) }

      assert_equal 0, StockMovement.count
      assert_equal BigDecimal(20), @item.reload.quantity
    end
  end

  test "funciona igual para un pool compartido (objeto stock_only con ProductStockSource)" do
    tapas = Preparation.create!(name: "Tapas CountRec #{rand(1_000_000)}", yield_quantity: 1, yield_unit: "un", stock_only: true)
    other = Product.create!(name: "Otro CountRec #{rand(1_000_000)}", category: @category, price_cents: 500, cost_cents: 200, active: true, position: 2)
    [ @product, other ].each { |p| ProductStockSource.create!(product: p, preparation: tapas) }
    @item.update!(active: false)
    pool = StockItem.create!(stockable: tapas, active: true, quantity: 50, minimum_quantity: 10, stock_tracking_started_on: Date.new(2026, 1, 1))
    todays_order(quantity: 4)
    todays_order(quantity: 6, product: other)

    at(14) do
      Stock::RegisterAdjustment.call(stock_item: pool, counted_quantity: 33, user: @user)
      Stock::DispatchReconciler.reconcile_due!

      assert_equal BigDecimal(33), pool.reload.quantity
      assert_equal 2, StockMovement.dispatch.where(stock_item: pool).count # una salida por pedido, una sola vez
      assert_equal [ -4, -6 ].sort, StockMovement.dispatch.where(stock_item: pool).pluck(:quantity).map(&:to_i).sort
    end
  end

  test "no altera otros StockItems más allá de aplicar sus propias salidas vencidas pendientes" do
    other_product = Product.create!(name: "Ajeno CountRec #{rand(1_000_000)}", category: @category, price_cents: 500, cost_cents: 200, active: true, position: 3)
    other_item = StockItem.create!(stockable: other_product, active: true, quantity: 30, minimum_quantity: 5, stock_tracking_started_on: Date.new(2026, 1, 1))

    at(14) do
      Stock::RegisterAdjustment.call(stock_item: @item, counted_quantity: 12, user: @user)

      assert_equal BigDecimal(30), other_item.reload.quantity
      assert_equal 0, other_item.stock_movements.count
    end
  end
end
