require "test_helper"
require_relative "../../support/retail_helpers"

# Producción: los pedidos minoristas se consolidan con los mayoristas en la MISMA planilla,
# sin crear pedidos artificiales.
class Retail::ProductionIntegrationTest < ActiveSupport::TestCase
  include RetailHelpers

  setup do
    setup_retail
    n = rand(1_000_000)
    @other_customer = Customer.create!(name: "Café Dos #{n}", active: true)
    @day = Date.new(2026, 10, 21)
  end

  def row_for(sheet, product)
    sheet.rows.find { |row| row[:product_id] == product.id }
  end

  test "suma por id real de producto: 20 + 15 + 12 = 47 con desglose por cliente y HANS" do
    wholesale_order(@mini, 20, @day)
    wholesale_order(@mini, 15, @day, customer: @other_customer)
    create_retail(attributes: { delivery_date: @day.iso8601 }, items: [product_row(@mini, 12, "500")])

    sheet = ProductionDaySheet.for(@day)
    row = row_for(sheet, @mini)

    assert_equal 47, row[:total]
    assert_equal 20, row[:quantities_by_customer][@customer.name]
    assert_equal 15, row[:quantities_by_customer][@other_customer.name]
    assert_equal 12, row[:quantities_by_customer]["HANS"]
    assert_includes sheet.customers, "HANS"
    assert_equal 1, sheet.rows.count { |r| r[:product_id] == @mini.id }
  end

  test "no se crean pedidos ni clientes mayoristas artificiales" do
    assert_no_difference ["Order.count", "OrderItem.count", "Customer.count"] do
      create_retail(attributes: { delivery_date: @day.iso8601 }, items: [product_row(@mini, 12, "500")])
      ProductionDaySheet.for(@day)
    end
  end

  test "solo minorista: aparece la columna HANS" do
    create_retail(attributes: { delivery_date: @day.iso8601 }, items: [product_row(@mini, 3, "500")])
    sheet = ProductionDaySheet.for(@day)

    assert_equal ["HANS"], sheet.customers
    assert_equal 3, row_for(sheet, @mini)[:total]
  end

  test "los productos manuales van aparte con comprador, horario y observaciones" do
    create_retail(
      attributes: { delivery_date: @day.iso8601, buyer_name: "Laura Gómez", delivery_time_note: "10 a 12", notes: "Sin nueces" },
      items: [product_row(@mini, 3, "500"), manual_row("Torta de cumpleaños", 1, "9.000")]
    )
    sheet = ProductionDaySheet.for(@day)

    assert_nil sheet.rows.find { |row| row[:product_name] == "Torta de cumpleaños" }
    item = sheet.special_items.sole
    assert_equal "Torta de cumpleaños", item.description
    assert_equal 1, item.quantity
    assert_equal "Laura Gómez", item.buyer_name
    assert_equal "10 a 12", item.time_note
    assert_equal "Sin nueces", item.notes
  end

  test "solo productos manuales: la planilla igual los muestra" do
    create_retail(attributes: { delivery_date: @day.iso8601 }, items: [manual_row("Mesa dulce", 1, "1.000")])
    sheet = ProductionDaySheet.for(@day)

    assert_not sheet.empty?
    assert_empty sheet.rows
    assert_equal 1, sheet.special_items.size
  end

  test "pedidos cancelados salen de producción" do
    order = create_retail(attributes: { delivery_date: @day.iso8601 }, items: [product_row(@mini, 3, "500"), manual_row("Especial", 1, "100")])
    Retail::ChangeStatus.call(order: order, to_status: "canceled", user: @admin)

    assert ProductionDaySheet.for(@day).empty?
  end

  test "cambiar la fecha o la cantidad actualiza producción" do
    order = create_retail(attributes: { delivery_date: @day.iso8601 }, items: [product_row(@mini, 3, "500")])
    rows = item_rows_for(order)
    rows[0]["quantity"] = "8"
    order = update_retail(order, attributes: { delivery_date: @day.iso8601 }, items: rows)
    assert_equal 8, row_for(ProductionDaySheet.for(@day), @mini)[:total]

    update_retail(order, attributes: { delivery_date: (@day + 1).iso8601 }, items: item_rows_for(order))
    assert ProductionDaySheet.for(@day).empty?
    assert_equal 8, row_for(ProductionDaySheet.for(@day + 1), @mini)[:total]
  end

  test "otras fechas no se mezclan" do
    create_retail(attributes: { delivery_date: (@day + 2).iso8601 }, items: [product_row(@mini, 3, "500")])
    assert ProductionDaySheet.for(@day).empty?
  end

  test "resumen del índice cuenta los pedidos minoristas" do
    wholesale_order(@mini, 5, @day)
    create_retail(attributes: { delivery_date: @day.iso8601 }, items: [product_row(@mini, 3, "500"), manual_row("X", 2, "1")])

    summary = ProductionDaySheet.day_summary(@day)
    assert_equal 2, summary[:orders_count]
    assert_equal 10, summary[:items_count]
    assert_equal 2, summary[:customers_count]
  end
end
