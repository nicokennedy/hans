require "test_helper"

# Historial de movimientos de stock (Stock::MovementHistory): solo lectura sobre el
# ledger existente. Se prueban los flujos reales (producción, conteo, descuento por
# pedido con corte de las 13:00, cancelación, modificación, pools) y que el historial
# no escriba nada ni invente saldos.
class Stock::MovementHistoryTest < ActiveSupport::TestCase
  DAY = Date.new(2026, 10, 5)

  def setup
    @admin = User.create!(email: "hist-admin-#{rand(1_000_000)}@example.com", password: "password123", role: "admin")
    @cook = User.create!(email: "hist-cook-#{rand(1_000_000)}@example.com", password: "password123", role: "production")
    @category = Category.create!(name: "HistCat#{rand(1_000_000)}", position: 1, active: true)
    @customer = Customer.create!(name: "Cliente Hist #{rand(1_000_000)}", active: true)
    @product = Product.create!(name: "Alfajor Hist #{rand(1_000_000)}", category: @category, price_cents: 500, cost_cents: 200, active: true, position: 1)
    @item = StockItem.create!(stockable: @product, active: true, quantity: 0, minimum_quantity: 10, stock_tracking_started_on: DAY)
  end

  def at(day, hour, min = 0, &block)
    travel_to(Time.zone.local(2026, 10, day, hour, min, 0), &block)
  end

  def order_for(delivery_date, items: { @product => 3 })
    order = Order.new(customer: @customer, delivery_date: delivery_date, status: "received", created_by_admin: true, payment_method_selected: "cash_on_delivery")
    items.each { |product, quantity| order.order_items.build(product: product, quantity: quantity) }
    order.save!
    order
  end

  def history(item = @item, **options)
    Stock::MovementHistory.new(item, **options)
  end

  # --- Producción y ajustes ---------------------------------------------------

  test "una producción aparece como ingreso con cantidad, usuario, comentario y stock resultante" do
    at(5, 9, 35) { Stock::RegisterProduction.call(stock_item: @item, quantity: 10, user: @cook, note: "Producción de la mañana") }

    entry = history.entries.first
    assert_equal "production", entry.kind
    assert_equal BigDecimal(10), entry.movement.quantity
    assert_equal BigDecimal(10), entry.movement.resulting_quantity
    assert_equal @cook, entry.user
    assert_equal "Producción de la mañana", entry.movement.note
    assert_equal Time.zone.local(2026, 10, 5, 9, 35), entry.movement.created_at
  end

  test "ajuste manual positivo y negativo: guarda la diferencia con usuario y motivo" do
    at(5, 9) { Stock::RegisterProduction.call(stock_item: @item, quantity: 30, user: @cook) }
    at(5, 10) { Stock::RegisterAdjustment.call(stock_item: @item, counted_quantity: 28, user: @admin, note: "Dos unidades descartadas por rotura") }
    at(5, 11) { Stock::RegisterAdjustment.call(stock_item: @item, counted_quantity: 31, user: @admin, note: "Faltaba contar una bandeja") }

    entries = history.entries
    assert_equal %w[adjustment adjustment production], entries.map(&:kind)
    assert_equal [BigDecimal(3), BigDecimal(-2), BigDecimal(30)], entries.map { |e| e.movement.quantity }
    assert_equal [BigDecimal(31), BigDecimal(28), BigDecimal(30)], entries.map { |e| e.movement.resulting_quantity }
    assert_equal [@admin, @admin, @cook], entries.map(&:user)
    assert_equal "Dos unidades descartadas por rotura", entries[1].movement.note
  end

  test "un movimiento anterior sin usuario no recibe ningún usuario ficticio" do
    @item.apply_movement!(movement_type: :production, quantity: 5) # sin user, como los registros viejos

    entry = history.entries.first
    assert_nil entry.user
    assert_nil entry.movement.user_id
  end

  # --- Ventas ----------------------------------------------------------------

  test "la venta de hoy (pasado el corte) queda vinculada al pedido correcto, con la fecha de entrega" do
    at(5, 14) do
      order = order_for(DAY)
      other = order_for(DAY, items: { @product => 2 })

      entries = history.entries
      assert_equal %w[sale sale], entries.map(&:kind)
      by_order = entries.index_by { |e| e.order.id }
      assert_equal BigDecimal(-3), by_order[order.id].movement.quantity
      assert_equal BigDecimal(-2), by_order[other.id].movement.quantity
      assert_equal DAY, by_order[order.id].order.delivery_date
      assert_equal [[@product.name, 3, BigDecimal(3)]], by_order[order.id].products
    end
  end

  test "un pedido futuro todavía no es un movimiento: es demanda comprometida" do
    at(5, 14) { order_for(DAY + 3) }

    assert_equal 0, history.total_count
    assert_equal BigDecimal(0), @item.reload.quantity
  end

  test "un pedido cargado un día y entregado otro conserva ambas fechas" do
    order = nil
    at(3, 10) { order = order_for(DAY) }
    at(5, 14) { Stock::DispatchReconciler.reconcile_due! }

    entry = history.entries.first
    assert_equal order, entry.order
    assert_equal DAY, entry.order.delivery_date
    assert_equal Date.new(2026, 10, 3), entry.order.created_at.to_date
  end

  # --- Cancelación / modificación ---------------------------------------------

  test "cancelar un pedido ya descontado agrega UNA corrección positiva y no duplica la salida" do
    at(5, 14) do
      order = order_for(DAY)
      assert_equal 1, @item.stock_movements.count

      order.update!(status: "canceled")
      2.times { Stock::DispatchReconciler.reconcile_due! }

      entries = history.entries
      assert_equal 2, entries.size
      assert_equal %w[correction sale], entries.map(&:kind)
      assert_equal [BigDecimal(3), BigDecimal(-3)], entries.map { |e| e.movement.quantity }
      assert_equal :canceled, entries.first.correction_reason
      assert_equal BigDecimal(0), entries.first.order_net, "neto del pedido: lo descontado se devolvió"
      assert_equal BigDecimal(0), @item.reload.quantity
      assert_equal [], entries.first.products, "un pedido cancelado no muestra detalle de consumo"
    end
  end

  test "reducir la cantidad de un pedido descontado agrega una corrección; aumentarla, otra venta de seguimiento" do
    order = item = nil
    at(5, 14) do
      order = order_for(DAY, items: { @product => 5 })
      item = order.order_items.first
    end
    at(5, 15) do
      item.update!(quantity: 3)
      Stock::DispatchReconciler.call(order)
    end
    at(5, 16) do
      item.update!(quantity: 4)
      Stock::DispatchReconciler.call(order)
    end

    entries = history.entries # más reciente primero
    assert_equal %w[sale correction sale], entries.map(&:kind)
    assert_equal [BigDecimal(-1), BigDecimal(2), BigDecimal(-5)], entries.map { |e| e.movement.quantity }
    assert_equal [true, false, false], entries.map(&:follow_up)
    assert_equal :modified, entries[1].correction_reason
    assert_equal BigDecimal(-4), entries[0].order_net
    assert_equal [[@product.name, 4, BigDecimal(4)]], entries[2].products, "el detalle va en la salida original y refleja el pedido actual"
    assert_equal BigDecimal(-4), @item.reload.quantity
  end

  # --- Pools compartidos --------------------------------------------------------

  test "dos productos que comparten una base descuentan del pool y el detalle los identifica" do
    base = Preparation.create!(name: "Base Hist #{rand(1_000_000)}", yield_quantity: 1, yield_unit: "un", stock_only: true)
    other = Product.create!(name: "Otro Hist #{rand(1_000_000)}", category: @category, price_cents: 500, cost_cents: 200, active: true, position: 2)
    [@product, other].each { |p| ProductStockSource.create!(product: p, preparation: base, quantity: 1) }
    pool = StockItem.create!(stockable: base, active: true, quantity: 0, minimum_quantity: 5, stock_tracking_started_on: DAY)
    @item.update!(active: false)
    @product = Product.find(@product.id) # sin la asociación stock_item cacheada de antes de desactivarlo

    at(5, 14) do
      order = order_for(DAY, items: { @product => 3, other => 2 })

      entries = history(pool).entries
      assert_equal [order], entries.map(&:order).uniq, "todas las salidas son del mismo pedido"
      assert_equal BigDecimal(-5), pool.stock_movements.where(order: order).sum(:quantity), "3 + 2 unidades, descontadas una sola vez"
      assert_equal BigDecimal(-5), entries.first.order_net
      assert_equal [false, false], entries.map(&:follow_up), "salidas del mismo lote no son una modificación del pedido"
      # el detalle por producto se lista una sola vez (en la primera salida del pedido)
      with_detail = entries.reject { |e| e.products.empty? }
      assert_equal 1, with_detail.size
      assert_equal [[@product.name, 3, BigDecimal(3)], [other.name, 2, BigDecimal(2)]].sort, with_detail.first.products.sort
      assert_equal 0, @item.stock_movements.where(order: order).count, "el ítem individual inactivo no descuenta"
    end
  end

  test "si la configuración del pool cambió y el detalle ya no cierra con lo descontado, se omite en vez de inventarlo" do
    base = Preparation.create!(name: "Base Hist2 #{rand(1_000_000)}", yield_quantity: 1, yield_unit: "un", stock_only: true)
    source = ProductStockSource.create!(product: @product, preparation: base, quantity: 1)
    pool = StockItem.create!(stockable: base, active: true, quantity: 0, minimum_quantity: 5, stock_tracking_started_on: DAY)
    @item.update!(active: false)
    @product = Product.find(@product.id)

    at(5, 14) do
      order_for(DAY)
      source.update!(quantity: 2) # hoy el producto descontaría 2 por unidad: 6 != 3

      entry = history(pool).entries.first
      assert_equal BigDecimal(-3), entry.movement.quantity
      assert_equal [], entry.products
    end
  end

  # --- Orden, filtros y paginación ---------------------------------------------

  test "orden cronológico descendente, desempatando por id cuando son del mismo instante" do
    at(5, 9) { 3.times { |i| @item.apply_movement!(movement_type: :production, quantity: i + 1, user: @cook) } }
    at(5, 8) { @item.apply_movement!(movement_type: :production, quantity: 10, user: @cook) }

    quantities = history.entries.map { |e| e.movement.quantity.to_i }
    assert_equal [3, 2, 1, 10], quantities # las de las 9:00 (más nuevas) primero; dentro de ellas, la última creada primero
  end

  test "filtros por tipo: producción, ventas, ajustes y cancelaciones/correcciones" do
    at(5, 9) { Stock::RegisterProduction.call(stock_item: @item, quantity: 20, user: @cook) }
    at(5, 10) { Stock::RegisterAdjustment.call(stock_item: @item, counted_quantity: 19, user: @admin, note: "rotura") }
    order = nil
    at(5, 14) { order = order_for(DAY) }
    at(5, 15) { order.update!(status: "canceled") }

    kinds = ->(filter) { history(filter: filter).entries.map(&:kind) }
    assert_equal %w[correction sale adjustment production], kinds.("all")
    assert_equal %w[production], kinds.("production")
    assert_equal %w[sale], kinds.("sale")
    assert_equal %w[adjustment], kinds.("adjustment")
    assert_equal %w[correction], kinds.("correction")
    assert_equal %w[correction sale adjustment production], kinds.("cualquier-cosa"), "un filtro desconocido equivale a Todos"
    assert_equal({ "all" => 4, "production" => 1, "sale" => 1, "adjustment" => 1, "correction" => 1 }, history.counts)
  end

  test "filtro por rango de fechas (zona Argentina, ambos extremos inclusive)" do
    at(3, 23, 30) { @item.apply_movement!(movement_type: :production, quantity: 1, user: @cook) }
    at(4, 0, 15) { @item.apply_movement!(movement_type: :production, quantity: 2, user: @cook) }
    at(4, 23, 59) { @item.apply_movement!(movement_type: :production, quantity: 3, user: @cook) }
    at(5, 0, 5) { @item.apply_movement!(movement_type: :production, quantity: 4, user: @cook) }

    quantities = ->(**opts) { history(**opts).entries.map { |e| e.movement.quantity.to_i } }
    assert_equal [3, 2], quantities.(from: "2026-10-04", to: "2026-10-04")
    assert_equal [4, 3, 2], quantities.(from: "2026-10-04")
    assert_equal [3, 2, 1], quantities.(to: "2026-10-04")
    assert_equal [1], quantities.(to: "2026-10-03")
  end

  test "una fecha inválida se ignora y se informa, sin romper" do
    h = history(from: "no-es-fecha", to: "2026-13-45")
    assert h.invalid_dates
    assert_nil h.from
    assert_nil h.to
    assert_equal 0, h.entries.size
  end

  test "paginación: 25 por página, páginas fuera de rango se acotan y no se pierde ningún movimiento" do
    at(5, 9) { 60.times { |i| @item.apply_movement!(movement_type: :production, quantity: 1, user: @cook, note: "m#{i}") } }

    first = history(page: 1)
    assert_equal 60, first.total_count
    assert_equal 3, first.total_pages
    assert_equal 25, first.entries.size
    assert_nil first.previous_page
    assert_equal 2, first.next_page

    last = history(page: 3)
    assert_equal 10, last.entries.size
    assert_equal 2, last.previous_page
    assert_nil last.next_page

    assert_equal 3, history(page: 99).page
    assert_equal 1, history(page: -4).page
    assert_equal 1, history(page: "x").page

    notes = (1..3).flat_map { |p| history(page: p).entries.map { |e| e.movement.note } }
    assert_equal (0...60).map { |i| "m#{i}" }.reverse, notes, "recorrer todas las páginas devuelve todo, en orden, sin repetir"
  end

  # --- Consistencia y ausencia de efectos secundarios ----------------------------

  test "el stock resultante de cada movimiento encadena y el último coincide con el stock actual" do
    at(5, 9) { Stock::RegisterProduction.call(stock_item: @item, quantity: 30, user: @cook) }
    at(5, 10) { Stock::RegisterAdjustment.call(stock_item: @item, counted_quantity: 27, user: @admin) }
    order = nil
    at(5, 14) { order = order_for(DAY, items: { @product => 4 }) }
    at(5, 15) { order.update!(status: "canceled") }
    at(5, 16) { Stock::RegisterProduction.call(stock_item: @item, quantity: 6, user: @cook) }

    chronological = history.entries.reverse.map(&:movement)
    running = BigDecimal(0)
    chronological.each do |movement|
      running += movement.quantity
      assert_equal running, movement.resulting_quantity, "el saldo del movimiento ##{movement.id} no encadena"
    end
    assert_equal @item.reload.quantity, chronological.last.resulting_quantity
    assert_equal @item.quantity, @item.stock_movements.sum(:quantity)
  end

  test "armar el historial no escribe nada: ni movimientos, ni stock, ni pedidos" do
    order = nil
    at(5, 14) { order = order_for(DAY) }
    at(5, 9) { Stock::RegisterProduction.call(stock_item: @item, quantity: 7, user: @cook) }
    before = [StockMovement.count, @item.reload.quantity, @item.updated_at, order.reload.updated_at, order.order_items.pluck(:quantity)]

    writes = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      writes << payload[:sql] if payload[:sql] =~ /\A\s*(INSERT|UPDATE|DELETE)/i
    end
    begin
      h = history
      h.entries
      h.counts
      h.total_pages
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert_empty writes
    assert_equal before, [StockMovement.count, @item.reload.quantity, @item.updated_at, order.reload.updated_at, order.order_items.pluck(:quantity)]
  end

  test "los movimientos del historial son de solo lectura" do
    @item.apply_movement!(movement_type: :production, quantity: 1, user: @cook)
    movement = history.entries.first.movement
    assert_raises(ActiveRecord::ReadOnlyRecord) { movement.update!(note: "editado") }
    assert_raises(ActiveRecord::ReadOnlyRecord) { movement.destroy! }
  end
end
