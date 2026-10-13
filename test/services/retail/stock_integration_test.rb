require "test_helper"
require_relative "../../support/retail_helpers"

# Los pedidos minoristas descuentan stock con el MISMO mecanismo que los mayoristas
# (Stock::DispatchReconciler): por fecha de entrega, por diferencia, sin duplicar movimientos.
class Retail::StockIntegrationTest < ActiveSupport::TestCase
  include RetailHelpers

  setup do
    setup_retail
    n = rand(1_000_000)
    @brownie = Preparation.create!(name: "Brownie Retail #{n}", yield_quantity: 1, yield_unit: "kg")
    @stock_item = StockItem.create!(stock_tracking_started_on: Date.new(2026, 1, 1), stockable: @brownie, active: true, quantity: 100, minimum_quantity: 2)
    # Producto mini: 1 unidad descuenta 1 del stock; torta no tiene stock propio.
    @cuadrado = make_product("Cuadrado Retail #{n}", 700)
    [@mini, @cuadrado].each do |product|
      product.create_product_recipe!(yield_quantity: 1).recipe_components.create!(component: @brownie, quantity: 1, unit: "kg")
    end
    @now = Time.zone.local(2026, 10, 20, 14, 0, 0) # martes 14:00: pasó el corte de las 13
    @past = Date.new(2026, 10, 18)
    @future = Date.new(2026, 10, 27)
  end

  def in_time(&block)
    travel_to(@now, &block)
  end

  def retail_net(order)
    StockMovement.dispatch.where(stock_item: @stock_item, retail_order: order).sum(:quantity)
  end

  test "entrega vencida: descuenta stock y el movimiento queda atado al pedido minorista" do
    in_time do
      order = create_retail(attributes: { delivery_date: @past.iso8601 }, items: [product_row(@mini, 12, "500")])

      assert_equal BigDecimal("88"), @stock_item.reload.quantity
      movement = StockMovement.dispatch.where(retail_order: order).sole
      assert_equal BigDecimal("-12"), movement.quantity
      assert_nil movement.order_id
    end
  end

  test "fecha futura: no descuenta todavía pero comprueba la demanda comprometida" do
    in_time do
      create_retail(attributes: { delivery_date: @future.iso8601 }, items: [product_row(@mini, 12, "500")])

      assert_equal BigDecimal("100"), @stock_item.reload.quantity
      snapshot = Stock::Availability.for_item(@stock_item)
      assert_equal BigDecimal("12"), snapshot.future_committed
      assert_equal BigDecimal("88"), snapshot.available_quantity
    end
  end

  test "hoy antes de las 13 no descuenta; a las 13 sí" do
    order = travel_to(Time.zone.local(2026, 10, 20, 9, 0, 0)) do
      created = create_retail(attributes: { delivery_date: "2026-10-20" }, items: [product_row(@mini, 5, "500")])
      assert_equal BigDecimal("100"), @stock_item.reload.quantity
      assert_equal BigDecimal("5"), Stock::Availability.for_item(@stock_item).today_dispatch
      created
    end

    travel_to(Time.zone.local(2026, 10, 20, 13, 0, 0)) do
      Stock::DispatchReconciler.reconcile_due!
      assert_equal BigDecimal("95"), @stock_item.reload.quantity
      Stock::DispatchReconciler.reconcile_due!
      assert_equal BigDecimal("95"), @stock_item.reload.quantity, "no duplica"
      assert_equal 1, StockMovement.dispatch.where(retail_order: order).count
    end
  end

  test "los productos manuales no afectan el stock ni crean movimientos" do
    in_time do
      order = create_retail(attributes: { delivery_date: @past.iso8601 }, items: [manual_row("Torta especial", 3, "5.000")])

      assert_equal BigDecimal("100"), @stock_item.reload.quantity
      assert_equal 0, StockMovement.where(retail_order: order).count
    end
  end

  test "pedido combinado descuenta solo los productos de catálogo" do
    in_time do
      create_retail(attributes: { delivery_date: @past.iso8601 }, items: [product_row(@mini, 4, "500"), manual_row("Especial", 10, "100")])
      assert_equal BigDecimal("96"), @stock_item.reload.quantity
    end
  end

  test "editar 12 -> 15 descuenta solo la diferencia (+3), sin doble descuento" do
    in_time do
      order = create_retail(attributes: { delivery_date: @past.iso8601 }, items: [product_row(@mini, 12, "500")])
      rows = item_rows_for(order)
      rows[0]["quantity"] = "15"
      update_retail(order, attributes: { delivery_date: @past.iso8601 }, items: rows)

      assert_equal BigDecimal("85"), @stock_item.reload.quantity
      assert_equal BigDecimal("-15"), retail_net(order)
      assert_equal [BigDecimal("-12"), BigDecimal("-3")], StockMovement.dispatch.where(retail_order: order).order(:id).pluck(:quantity)

      # guardar sin cambios no genera movimientos
      assert_no_difference -> { StockMovement.count } do
        update_retail(order, attributes: { delivery_date: @past.iso8601 }, items: item_rows_for(order))
      end
    end
  end

  test "reducir la cantidad devuelve la diferencia" do
    in_time do
      order = create_retail(attributes: { delivery_date: @past.iso8601 }, items: [product_row(@mini, 12, "500")])
      rows = item_rows_for(order)
      rows[0]["quantity"] = "10"
      update_retail(order, attributes: { delivery_date: @past.iso8601 }, items: rows)

      assert_equal BigDecimal("90"), @stock_item.reload.quantity
      assert_equal BigDecimal("-10"), retail_net(order)
    end
  end

  test "cambiar la fecha mueve la demanda: a futuro devuelve, de nuevo al pasado vuelve a descontar" do
    in_time do
      order = create_retail(attributes: { delivery_date: @past.iso8601 }, items: [product_row(@mini, 12, "500")])
      assert_equal BigDecimal("88"), @stock_item.reload.quantity

      update_retail(order, attributes: { delivery_date: @future.iso8601 }, items: item_rows_for(order))
      assert_equal BigDecimal("100"), @stock_item.reload.quantity
      assert_equal BigDecimal("12"), Stock::Availability.for_item(@stock_item).future_committed

      update_retail(order, attributes: { delivery_date: @past.iso8601 }, items: item_rows_for(order))
      assert_equal BigDecimal("88"), @stock_item.reload.quantity
      assert_equal BigDecimal("-12"), retail_net(order)
    end
  end

  test "cancelar devuelve el stock ya descontado, conserva el historial y los pagos" do
    in_time do
      order = create_retail(attributes: { delivery_date: @past.iso8601 }, items: [product_row(@mini, 12, "500")])
      pay_retail(order, "1.000")
      assert_equal BigDecimal("88"), @stock_item.reload.quantity

      assert Retail::ChangeStatus.call(order: order, to_status: "canceled", user: @admin, note: "El comprador no vino").ok?

      assert_equal BigDecimal("100"), @stock_item.reload.quantity
      assert_equal 0, retail_net(order)
      assert_equal 2, StockMovement.dispatch.where(retail_order: order).count, "los movimientos originales se conservan"
      assert_equal pesos(1_000), order.reload.amount_paid_cents
      assert_equal %w[pending canceled], order.retail_order_status_changes.map(&:to_status)
      assert_equal "El comprador no vino", order.retail_order_status_changes.last.note

      # cancelar de nuevo / reconciliar no duplica
      Stock::DispatchReconciler.reconcile_due!
      assert_equal BigDecimal("100"), @stock_item.reload.quantity
    end
  end

  test "un pedido cancelado deja de comprometer stock futuro" do
    in_time do
      order = create_retail(attributes: { delivery_date: @future.iso8601 }, items: [product_row(@mini, 12, "500")])
      assert_equal BigDecimal("12"), Stock::Availability.for_item(@stock_item).future_committed

      Retail::ChangeStatus.call(order: order, to_status: "canceled", user: @admin)
      assert_equal BigDecimal("0"), Stock::Availability.for_item(@stock_item).future_committed
    end
  end

  test "reactivar un pedido cancelado vuelve a descontar" do
    in_time do
      order = create_retail(attributes: { delivery_date: @past.iso8601 }, items: [product_row(@mini, 2, "500")])
      Retail::ChangeStatus.call(order: order, to_status: "canceled", user: @admin)
      Retail::ChangeStatus.call(order: order, to_status: "pending", user: @admin)

      assert_equal BigDecimal("98"), @stock_item.reload.quantity
    end
  end

  test "mayorista y minorista conviven sobre el mismo stock sin pisarse" do
    in_time do
      wholesale = wholesale_order(@mini, 20, @past)
      retail = create_retail(attributes: { delivery_date: @past.iso8601 }, items: [product_row(@cuadrado, 15, "700")])

      assert_equal BigDecimal("65"), @stock_item.reload.quantity
      assert_equal BigDecimal("-20"), StockMovement.dispatch.where(order: wholesale).sum(:quantity)
      assert_equal BigDecimal("-15"), retail_net(retail)

      Stock::DispatchReconciler.reconcile_due!
      assert_equal BigDecimal("65"), @stock_item.reload.quantity
    end
  end

  test "pool compartido: dos productos de un mismo pool descuentan del mismo stock" do
    in_time do
      pool = Preparation.create!(name: "Pool Retail #{rand(1_000_000)}", yield_quantity: 1, yield_unit: "un", stock_only: true)
      pool_item = StockItem.create!(stock_tracking_started_on: Date.new(2026, 1, 1), stockable: pool, active: true, quantity: 50, minimum_quantity: 1)
      a = make_product("Alfajor A #{rand(1_000_000)}", 300)
      b = make_product("Alfajor B #{rand(1_000_000)}", 300)
      [a, b].each { |product| ProductStockSource.create!(product: product, preparation: pool, quantity: 1) }

      wholesale_order(a, 10, @past)
      create_retail(attributes: { delivery_date: @past.iso8601 }, items: [product_row(a, 5, "300"), product_row(b, 7, "300")])

      assert_equal BigDecimal("28"), pool_item.reload.quantity
    end
  end

  test "el historial de movimientos muestra el pedido minorista" do
    in_time do
      order = create_retail(attributes: { delivery_date: @past.iso8601 }, items: [product_row(@mini, 12, "500")])
      entry = Stock::MovementHistory.new(@stock_item).entries.first

      assert_equal order, entry.retail_order
      assert_nil entry.order
      assert_equal "sale", entry.kind
      assert_equal [[@mini.name, 12, BigDecimal("12")]], entry.products

      Retail::ChangeStatus.call(order: order, to_status: "canceled", user: @admin)
      correction = Stock::MovementHistory.new(@stock_item).entries.first
      assert_equal "correction", correction.kind
      assert_equal :canceled, correction.correction_reason
    end
  end

  test "un movimiento no puede pertenecer a un pedido mayorista y a uno minorista a la vez" do
    in_time do
      retail = create_retail
      wholesale = wholesale_order(@mini, 1, @future)
      movement = StockMovement.new(stock_item: @stock_item, movement_type: "dispatch", quantity: -1, resulting_quantity: 99, order: wholesale, retail_order: retail)
      assert_not movement.valid?
    end
  end
end
