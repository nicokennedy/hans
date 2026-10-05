require "test_helper"

# stock_tracking_started_on: un StockItem solo participa del control de stock
# para pedidos con delivery_date >= esa fecha. Pedidos anteriores se ignoran:
# no comprometen, no descuentan y no generan movimientos. Se compara contra el
# delivery_date del pedido (no contra created_at del pedido ni del StockItem).
class Stock::TrackingStartTest < ActiveSupport::TestCase
  START = Date.new(2026, 10, 5)

  def setup
    @category = Category.create!(name: "TrackCat#{rand(1_000_000)}", position: 1, active: true)
    @customer = Customer.create!(name: "Cliente Track #{rand(1_000_000)}", active: true)
    @product = Product.create!(name: "Alfajor Track #{rand(1_000_000)}", category: @category, price_cents: 500, cost_cents: 200, active: true, position: 1)
    @item = StockItem.create!(stockable: @product, active: true, quantity: 0, minimum_quantity: 10, stock_tracking_started_on: START)
  end

  def at(day, hour, min = 0, &block)
    travel_to(Time.zone.local(2026, 10, day, hour, min, 0), &block)
  end

  def order_for(delivery_date, quantity: 3, product: @product, status: "received")
    order = Order.new(customer: @customer, delivery_date: delivery_date, status: status, created_by_admin: true, payment_method_selected: "cash_on_delivery")
    order.order_items.build(product: product, quantity: quantity)
    order.save!
    order
  end

  def snapshot(item = @item)
    Stock::Availability.for_item(item)
  end

  def dispatch_count
    StockMovement.dispatch.count
  end

  # --- La regla central ---------------------------------------------------

  test "pedido del 04/10 (anterior al inicio): no compromete, no descuenta, no genera movimiento" do
    at(5, 14) do
      order_for(Date.new(2026, 10, 4))

      Stock::DispatchReconciler.reconcile_due!
      s = snapshot

      assert_equal BigDecimal(0), s.future_committed
      assert_equal BigDecimal(0), s.today_dispatch
      assert_equal BigDecimal(0), @item.reload.quantity
      assert_equal 0, dispatch_count
    end
  end

  test "pedido del 05/10 (el día de inicio): sigue la lógica normal del corte de las 13:00" do
    order = nil
    at(5, 9) { order = order_for(START) }

    at(5, 12, 59) do
      Stock::DispatchReconciler.call(order)
      s = snapshot
      assert_equal 0, dispatch_count
      assert_equal BigDecimal(3), s.today_dispatch
      assert_not s.today_dispatch_materialized
      assert_equal BigDecimal(-3), s.available_quantity # 0 - salidas de hoy pendientes
    end

    at(5, 13, 0) do
      Stock::DispatchReconciler.call(order)
      assert_equal 1, dispatch_count
      assert_equal BigDecimal(-3), @item.reload.quantity
      assert_equal BigDecimal(-3), snapshot.available_quantity # no se resta dos veces
    end
  end

  test "pedido del 06/10: compromiso futuro normal" do
    at(5, 9) do
      order_for(Date.new(2026, 10, 6), quantity: 4)

      s = snapshot
      assert_equal BigDecimal(4), s.future_committed
      assert_equal BigDecimal(-4), s.available_quantity
      assert_equal 0, dispatch_count
    end
  end

  test "conciliar varias veces no duplica movimientos" do
    order = nil
    at(5, 9) do
      order_for(Date.new(2026, 10, 4))
      order = order_for(START)
      order_for(Date.new(2026, 10, 6))
    end

    at(5, 15) do
      3.times { Stock::DispatchReconciler.reconcile_due!; snapshot }
      assert_equal 1, dispatch_count
      assert_equal 1, StockMovement.dispatch.where(order: order).count
      assert_equal BigDecimal(-3), @item.reload.quantity
    end
  end

  # --- Modificar / cancelar / mover pedidos -------------------------------

  test "modificar o cancelar un pedido anterior al inicio no genera ningún movimiento" do
    at(5, 14) do
      order = order_for(Date.new(2026, 10, 3))
      order.order_items.first.update!(quantity: 9)
      order.update!(status: "canceled")
      order.update!(status: "received")
      Stock::DispatchReconciler.reconcile_due!

      assert_equal 0, StockMovement.count
      assert_equal BigDecimal(0), @item.reload.quantity
    end
  end

  test "mover un pedido de antes del inicio a después empieza a afectar el stock" do
    at(5, 14) do
      order = order_for(Date.new(2026, 10, 4))
      assert_equal 0, dispatch_count

      order.update!(delivery_date: START) # hoy, ya pasó el corte
      assert_equal 1, dispatch_count
      assert_equal BigDecimal(-3), @item.reload.quantity

      order.update!(delivery_date: Date.new(2026, 10, 7)) # a futuro: se revierte y pasa a comprometido
      assert_equal BigDecimal(0), @item.reload.quantity
      assert_equal BigDecimal(3), snapshot.future_committed
    end
  end

  test "mover a futuro un pedido anterior al inicio lo compromete normalmente, sin movimientos" do
    at(5, 9) do
      order = order_for(Date.new(2026, 10, 4))
      order.update!(delivery_date: Date.new(2026, 10, 8))

      assert_equal BigDecimal(3), snapshot.future_committed
      assert_equal 0, StockMovement.count
    end
  end

  test "mover un pedido de después a antes del inicio: un compromiso futuro desaparece sin dejar movimientos" do
    at(5, 9) do
      order = order_for(Date.new(2026, 10, 7))
      assert_equal BigDecimal(3), snapshot.future_committed

      order.update!(delivery_date: Date.new(2026, 10, 3))

      assert_equal BigDecimal(0), snapshot.future_committed
      assert_equal 0, StockMovement.count
    end
  end

  test "mover un pedido ya descontado a antes del inicio revierte su salida: el físico vuelve y el neto queda en cero" do
    at(5, 14) do
      order = order_for(START)
      assert_equal BigDecimal(-3), @item.reload.quantity

      order.update!(delivery_date: Date.new(2026, 10, 3))

      assert_equal BigDecimal(0), @item.reload.quantity
      assert_equal BigDecimal(0), StockMovement.dispatch.where(order: order).sum(:quantity)
      Stock::DispatchReconciler.reconcile_due!
      assert_equal 2, StockMovement.count # la salida y su reversión, nada más
    end
  end

  # --- Pools y productos ---------------------------------------------------

  test "un pool compartido (ProductStockSource) respeta la fecha de inicio" do
    tapas = Preparation.create!(name: "Tapas Track #{rand(1_000_000)}", yield_quantity: 1, yield_unit: "un", stock_only: true)
    other = Product.create!(name: "Otro Alfajor Track #{rand(1_000_000)}", category: @category, price_cents: 500, cost_cents: 200, active: true, position: 2)
    [ @product, other ].each { |product| ProductStockSource.create!(product: product, preparation: tapas) }
    @item.update!(active: false)
    pool = StockItem.create!(stockable: tapas, active: true, quantity: 0, minimum_quantity: 10, stock_tracking_started_on: START)

    at(5, 14) do
      order_for(Date.new(2026, 10, 4), quantity: 5)
      order_for(Date.new(2026, 10, 4), quantity: 2, product: other)
      today_order = order_for(START, quantity: 4, product: other)
      order_for(Date.new(2026, 10, 6), quantity: 6)

      Stock::DispatchReconciler.reconcile_due!
      s = snapshot(pool)

      assert_equal BigDecimal(6), s.future_committed # solo el del 06/10
      assert_equal BigDecimal(-4), pool.reload.quantity # solo el del 05/10, ya pasó el corte
      assert_equal [ today_order.id ], StockMovement.dispatch.where(stock_item: pool).pluck(:order_id)
    end
  end

  test "la fecha de inicio es de cada StockItem: uno más antiguo sí cuenta pedidos que otro ignora" do
    older = Product.create!(name: "Mini Track #{rand(1_000_000)}", category: @category, price_cents: 500, cost_cents: 200, active: true, position: 3)
    older_item = StockItem.create!(stockable: older, active: true, quantity: 10, minimum_quantity: 1, stock_tracking_started_on: Date.new(2026, 10, 1))

    at(5, 14) do
      order_for(Date.new(2026, 10, 3), product: older, quantity: 2)
      order_for(Date.new(2026, 10, 3), product: @product, quantity: 2)
      Stock::DispatchReconciler.reconcile_due!

      assert_equal BigDecimal(8), older_item.reload.quantity # 10 - 2: el 03/10 sí cuenta para él
      assert_equal BigDecimal(0), @item.reload.quantity # y no para el que empieza el 05/10
    end
  end

  test "una fecha de inicio a futuro ignora todo hasta ese día, incluso las salidas de hoy" do
    @item.update!(stock_tracking_started_on: Date.new(2026, 10, 10))

    at(5, 14) do
      order_for(START, quantity: 4)
      order_for(Date.new(2026, 10, 7), quantity: 5)
      order_for(Date.new(2026, 10, 10), quantity: 6)
      Stock::DispatchReconciler.reconcile_due!

      s = snapshot
      assert_equal BigDecimal(6), s.future_committed # solo el del 10/10
      assert_equal BigDecimal(0), s.today_dispatch
      assert_equal 0, StockMovement.count
    end
  end

  # --- La frontera es explícita, no created_at -----------------------------

  test "no depende de created_at: un ítem creado hoy con inicio anterior sí cuenta pedidos viejos" do
    other = Product.create!(name: "Viejo Track #{rand(1_000_000)}", category: @category, price_cents: 500, cost_cents: 200, active: true, position: 4)
    item = nil
    at(5, 14) do
      item = StockItem.create!(stockable: other, active: true, quantity: 10, minimum_quantity: 1, stock_tracking_started_on: Date.new(2026, 9, 1))
      order_for(Date.new(2026, 9, 20), product: other, quantity: 3)
      Stock::DispatchReconciler.reconcile_due!

      assert_equal BigDecimal(7), item.reload.quantity
    end
  end

  test "un StockItem nuevo arranca por defecto hoy, y la fecha es obligatoria" do
    other = Product.create!(name: "Nuevo Track #{rand(1_000_000)}", category: @category, price_cents: 500, cost_cents: 200, active: true, position: 5)

    at(8, 10) do
      assert_equal Date.new(2026, 10, 8), StockItem.new(stockable: other, quantity: 0, minimum_quantity: 1).stock_tracking_started_on
    end

    item = StockItem.new(stockable: other, quantity: 0, minimum_quantity: 1, stock_tracking_started_on: nil)
    assert_not item.valid?
    assert item.errors[:stock_tracking_started_on].present?
  end

  # --- Eficiencia y validación previa --------------------------------------

  test "la conciliación no recorre pedidos anteriores a la fecha de inicio más temprana" do
    at(5, 14) do
      old = order_for(Date.new(2026, 9, 1))
      recent = order_for(START)

      candidates = Stock::DispatchReconciler.candidate_orders
      assert_includes candidates, recent
      assert_not_includes candidates, old
    end
  end

  test "InsufficientStockChecker no hace competir a un pedido anterior al inicio por este stock" do
    @product.update!(sell_without_stock: false)
    order = Order.new(customer: @customer, delivery_date: Date.new(2026, 10, 3), payment_method_selected: "cash_on_delivery")
    order.order_items.build(product: @product, quantity: 50)

    assert_equal [], Stock::InsufficientStockChecker.violations_for(order)
  end
end
