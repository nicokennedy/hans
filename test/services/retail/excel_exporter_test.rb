require "test_helper"
require_relative "../../support/retail_helpers"
require_relative "../../support/xlsx_reader"

class Retail::ExcelExporterTest < ActiveSupport::TestCase
  include RetailHelpers

  setup do
    setup_retail
    @d1 = Date.new(2026, 10, 21)
    @d2 = Date.new(2026, 10, 25)
  end

  def export(scope = RetailOrder.all)
    XlsxReader.new(Retail::ExcelExporter.new(scope).call)
  end

  def detail(xlsx)
    xlsx.rows("Detalle de productos")
  end

  def summary(xlsx)
    xlsx.rows("Resumen de pedidos")
  end

  test "es un .xlsx real con dos hojas y encabezados en español" do
    data = Retail::ExcelExporter.new(RetailOrder.all).call
    assert_equal "PK", data.byteslice(0, 2), "un .xlsx es un zip"
    xlsx = XlsxReader.new(data)

    assert_equal ["Detalle de productos", "Resumen de pedidos"], xlsx.sheet_names
    assert_equal Retail::ExcelExporter::DETAIL_HEADERS, detail(xlsx).first
    assert_equal Retail::ExcelExporter::SUMMARY_HEADERS, summary(xlsx).first
    assert_equal 16, Retail::ExcelExporter::DETAIL_HEADERS.size
    assert_equal 16, Retail::ExcelExporter::SUMMARY_HEADERS.size
    assert_equal 1, detail(xlsx).size, "sin pedidos: solo encabezados"
  end

  test "una fila por ítem, con productos de catálogo y manuales y varios productos por pedido" do
    order = create_retail(
      attributes: { delivery_date: @d1.iso8601, buyer_name: "María González", buyer_phone: "11 5555-1234", delivery_kind: "delivery", address: "Calle 123", delivery_time_note: "15 a 16", notes: "Sin nueces", shipping: "1.000" },
      items: [product_row(@mini, 12, "3.000"), product_row(@torta, 1, "32.000"), manual_row("Torta 'Frozen' c/ =CARTEL+1", 2, "7.500,50")]
    )
    other = create_retail(attributes: { delivery_date: @d1.iso8601, buyer_name: "Juan Pérez" }, items: [product_row(@mini, 6, "4.500")])

    rows = detail(export)
    assert_equal 5, rows.size # encabezado + 3 + 1

    first = rows[1]
    assert_equal order.number, first[0]
    assert_equal order.created_at.to_date, first[1]
    assert_equal @d1, first[2]
    assert_equal "15 a 16", first[3]
    assert_equal "María González", first[4]
    assert_equal "11 5555-1234", first[5]
    assert_equal "Delivery", first[6]
    assert_equal "Calle 123", first[7]
    assert_equal @mini.name, first[8]
    assert_equal "Catálogo", first[9]
    assert_equal 12, first[10]
    assert_equal 3000, first[11]
    assert_equal 36_000, first[12]
    assert_equal "Sin nueces", first[13]
    assert_equal "Pendiente", first[14]
    assert_equal "Pendiente", first[15]

    assert_equal @torta.name, rows[2][8]
    manual = rows[3]
    assert_equal "Torta 'Frozen' c/ =CARTEL+1", manual[8], "la descripción manual queda exacta"
    assert_equal "Manual", manual[9]
    assert_equal 2, manual[10]
    assert_equal 7500.5, manual[11]
    assert_equal 15_001, manual[12]
    assert_equal order.number, manual[0]

    assert_equal [other.number, "Juan Pérez"], [rows[4][0], rows[4][4]], "compradores distintos no se agrupan"
    assert_equal 6, rows[4][10]
  end

  test "los textos son strings (nunca fórmulas) aunque empiecen con = + - @" do
    create_retail(attributes: { delivery_date: @d1.iso8601, buyer_name: "=HYPERLINK(\"x\")" }, items: [manual_row("=1+1", 1, "10"), manual_row("@SUM(A1)", 1, "10"), manual_row("-cmd", 1, "10"), manual_row("+54 11", 1, "10")])
    xlsx = export

    xlsx.cells("Detalle de productos").drop(1).each do |row|
      assert_includes %w[inlineStr s str], row[8].type, "producto como texto"
      assert_includes %w[inlineStr s str], row[4].type, "comprador como texto"
    end
    assert_empty xlsx.xml("Detalle de productos").xpath("//f")
    assert_equal ["=1+1", "@SUM(A1)", "-cmd", "+54 11"], detail(xlsx).drop(1).map { |r| r[8] }
  end

  test "resumen: una fila por pedido; envío y pagos no se duplican por producto" do
    order = create_retail(
      attributes: { delivery_date: @d1.iso8601, buyer_name: "María González", delivery_kind: "pickup", shipping: "1.500", planned_payment_method: "openpay", notes: "Obs resumen" },
      items: [product_row(@mini, 10, "1.000"), product_row(@torta, 1, "5.000"), manual_row("Extra", 1, "500")]
    ) # subtotal 15.500, total 17.000
    pay_retail(order, "4.000")
    pay_retail(order, "3.000", method: "cash_on_delivery")

    xlsx = export
    assert_equal 4, detail(xlsx).size
    rows = summary(xlsx)
    assert_equal 2, rows.size
    row = rows[1]
    assert_equal order.number, row[0]
    assert_equal @d1, row[1]
    assert_equal "María González", row[3]
    assert_equal "Retiro", row[5]
    assert_equal 15_500, row[7]
    assert_equal 1500, row[8]
    assert_equal 17_000, row[9]
    assert_equal 7000, row[10]
    assert_equal 10_000, row[11]
    assert_equal "Openpay", row[12]
    assert_equal "Parcial", row[13]
    assert_equal "Pendiente", row[14]
    assert_equal "Obs resumen", row[15]
  end

  test "pagado, pendiente y cancelado quedan identificados con importes correctos" do
    paid = create_retail(attributes: { delivery_date: @d1.iso8601, buyer_name: "A Paga" }, items: [product_row(@mini, 2, "500")])
    pay_retail(paid, "1.000")
    pending = create_retail(attributes: { delivery_date: @d1.iso8601, buyer_name: "B Debe" }, items: [product_row(@mini, 4, "500")])
    canceled = create_retail(attributes: { delivery_date: @d1.iso8601, buyer_name: "C Cancela" }, items: [product_row(@mini, 1, "500")])
    pay_retail(canceled, "200")
    Retail::ChangeStatus.call(order: canceled, to_status: "canceled", user: @admin)

    rows = summary(export).drop(1).index_by { |r| r[3] }
    assert_equal ["Pagado", "Pendiente", 0, 1000], [rows["A Paga"][13], rows["A Paga"][14], rows["A Paga"][11], rows["A Paga"][10]]
    assert_equal ["Pendiente", "Pendiente", 2000, 0], [rows["B Debe"][13], rows["B Debe"][14], rows["B Debe"][11], rows["B Debe"][10]]
    assert_equal ["Parcial", "Cancelado", 300, 200], [rows["C Cancela"][13], rows["C Cancela"][14], rows["C Cancela"][11], rows["C Cancela"][10]]
    detail_c = detail(export).drop(1).find { |r| r[4] == "C Cancela" }
    assert_equal "Cancelado", detail_c[14]
  end

  test "los pagos anulados no cuentan como pagado" do
    order = create_retail(attributes: { delivery_date: @d1.iso8601 }, items: [product_row(@mini, 10, "1.000")])
    payment = pay_retail(order, "6.000").record
    Retail::VoidPayment.call(payment: payment, user: @admin, reason: "error")

    row = summary(export)[1]
    assert_equal [0, 10_000, "Pendiente"], [row[10], row[11], row[13]]
  end

  test "ordena por fecha de entrega y número de pedido" do
    late = create_retail(attributes: { delivery_date: @d2.iso8601, buyer_name: "Tarde" })
    early_b = create_retail(attributes: { delivery_date: @d1.iso8601, buyer_name: "Temprano 2" })
    early_a = create_retail(attributes: { delivery_date: @d1.iso8601, buyer_name: "Temprano 1" })
    early_a_first = [early_b, early_a].min_by(&:id)

    assert_equal [early_a_first.buyer_name, ([early_b, early_a] - [early_a_first]).first.buyer_name, "Tarde"], summary(export).drop(1).map { |r| r[3] }
    assert_equal [late.number], summary(export).drop(1).map { |r| r[0] }.last(1)
  end

  test "formato: fechas de Excel, cantidades numéricas, moneda, autofiltro y primera fila congelada" do
    create_retail(attributes: { delivery_date: @d1.iso8601, shipping: "100" }, items: [product_row(@mini, 3, "1.234,56")])
    xlsx = export

    data_row = xlsx.cells("Detalle de productos")[1]
    assert_equal "dd/mm/yyyy", data_row[1].format
    assert_equal "dd/mm/yyyy", data_row[2].format
    assert_equal Date, data_row[2].value.class
    assert_not_equal "inlineStr", data_row[2].type, "la fecha no es texto"
    assert_equal "0", data_row[10].format
    assert_kind_of Integer, data_row[10].value
    assert_equal "$#,##0.00", data_row[11].format
    assert_equal "$#,##0.00", data_row[12].format
    assert_in_delta 3703.68, data_row[12].value, 0.001

    summary_row = xlsx.cells("Resumen de pedidos")[1]
    assert_equal "$#,##0.00", summary_row[7].format
    assert_equal "$#,##0.00", summary_row[11].format
    assert_equal "dd/mm/yyyy", summary_row[1].format

    { "Detalle de productos" => "P2", "Resumen de pedidos" => "P2" }.each do |name, last|
      sheet = xlsx.xml(name)
      assert_equal "A1:#{last}", sheet.at_xpath("//autoFilter")["ref"], "autofiltro en #{name}"
      pane = sheet.at_xpath("//sheetView/pane")
      assert_equal "frozen", pane["state"]
      assert_equal "1", pane["ySplit"]
      assert_equal "A2", pane["topLeftCell"]
      assert sheet.xpath("//cols/col").size >= 16, "anchos de columna definidos"
    end
    styles = xlsx.parts["xl/styles.xml"]
    assert_match(/<b val="1"\/>/, styles, "encabezados en negrita")
  end

  test "tildes y caracteres especiales se conservan" do
    create_retail(attributes: { delivery_date: @d1.iso8601, buyer_name: "José Ñandú Müller", address: "Av. Rivadavia 1234 – 5° «B»", notes: "Cumpleaños de Inés 🎂 ¡sin maní!" }, items: [manual_row("Torta Tres Leches ñoña", 1, "100")])
    row = detail(export)[1]

    assert_equal "José Ñandú Müller", row[4]
    assert_equal "Av. Rivadavia 1234 – 5° «B»", row[7]
    assert_equal "Torta Tres Leches ñoña", row[8]
    assert_equal "Cumpleaños de Inés 🎂 ¡sin maní!", row[13]
  end

  test "el nombre de archivo lleva la fecha" do
    assert_equal "pedidos_minoristas_2026-10-14.xlsx", Retail::ExcelExporter.filename(Date.new(2026, 10, 14))
  end

  test "es de solo lectura: no cambia pedidos, pagos, stock ni producción" do
    order = create_retail(attributes: { delivery_date: @d1.iso8601 }, items: [product_row(@mini, 5, "500"), manual_row("X", 1, "1")])
    pay_retail(order, "1.000")
    snapshot = lambda do
      [RetailOrder.pluck(:id, :updated_at, :total_cents, :amount_paid_cents, :status), RetailOrderItem.pluck(:id, :updated_at), RetailOrderPayment.pluck(:id, :updated_at),
       StockMovement.count, StockItem.pluck(:id, :quantity), Order.count, Payment.count, CustomerPayment.count, Product.pluck(:id, :price_cents), ProductionDaySheet.for(@d1).rows]
    end
    before = snapshot.call

    export

    assert_equal before, snapshot.call
  end

  test "sin N+1: las consultas no crecen con la cantidad de pedidos" do
    create_retail(attributes: { delivery_date: @d1.iso8601 }, items: [product_row(@mini, 1, "1"), manual_row("a", 1, "1")])
    count_queries = lambda do
      n = 0
      counter = ->(*, payload) { n += 1 unless payload[:name] == "SCHEMA" || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|SAVEPOINT|RELEASE)/i) }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { Retail::ExcelExporter.new(RetailOrder.all).call }
      n
    end
    small = count_queries.call
    6.times { |i| create_retail(attributes: { delivery_date: @d1.iso8601, buyer_name: "N#{i}" }, items: [product_row(@mini, 1, "1"), product_row(@torta, 2, "2"), manual_row("b", 1, "1")]) }

    assert_equal small, count_queries.call
  end
end
