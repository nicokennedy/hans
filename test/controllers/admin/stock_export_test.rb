require "test_helper"
require_relative "../../support/xlsx_reader"

# Exportación del panel de Stock a Excel para el control físico (ver Stock::ExcelExporter).
class Admin::StockExportTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  DAY = Date.new(2026, 10, 6)
  HEADERS = Stock::ExcelExporter::HEADERS

  setup do
    @admin = User.create!(email: "stockexport-admin@example.com", password: "password123", role: "admin")
    @production = User.create!(email: "stockexport-production@example.com", password: "password123", role: "production")
    customer = Customer.create!(name: "StockExport Cliente", active: true)
    @customer = customer
    @customer_user = User.create!(email: "stockexport-customer@example.com", password: "password123", role: "customer", customer: customer)

    raw = RawMaterial.create!(name: "RM StockExport", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    category = Category.create!(name: "StockExport Cat", position: 1, active: true)

    @brownie = build_preparation("Brownie export", raw)
    @mini = Product.create!(name: "Mini export", category: category, price_cents: 500, cost_cents: 200, active: true, position: 1)
    ProductRecipe.create!(product: @mini, yield_quantity: 1).recipe_components.create!(component: @brownie, quantity: 1, unit: "kg")

    # Disponible = 10 - 2 (futuro) - 3 (hoy, antes de las 13) = 5 < mínimo 8 -> producir 3.
    @brownie_item = stock_item(@brownie, quantity: 10, minimum: 8)
    @negative_item = stock_item(build_preparation("Ábaco negativo", raw), quantity: -4, minimum: 2)
    @plenty_item = stock_item(build_preparation("Crema sobrante", raw), quantity: 50, minimum: 5)
    @zero_min_item = stock_item(build_preparation("Dulce sin mínimo", raw), quantity: 7, minimum: 0)
    @batch_item = stock_item(build_preparation("Masa con lote", raw), quantity: 1, minimum: 10, batch: 4) # faltan 9 -> 3 tandas = 12
    @inactive_item = stock_item(build_preparation("Zeta inactiva", raw), quantity: 3, minimum: 1, active: false)

    at(9) do
      build_order(DAY + 5, 2)
      build_order(DAY, 3)
    end
  end

  def build_preparation(name, raw)
    Preparation.create!(name: name, yield_quantity: 1, yield_unit: "kg").tap { |p| p.recipe_components.create!(component: raw, quantity: 1, unit: "kg") }
  end

  def stock_item(stockable, quantity:, minimum:, batch: nil, active: true)
    StockItem.create!(stock_tracking_started_on: Date.new(2026, 1, 1), stockable: stockable, active: active,
                      quantity: quantity, minimum_quantity: minimum, production_batch_size: batch)
  end

  def build_order(date, quantity)
    order = Order.new(customer: @customer, delivery_date: date, created_by_admin: true, payment_method_selected: "cash_on_delivery")
    order.order_items.build(product: @mini, quantity: quantity)
    order.save!
  end

  def at(hour, &block)
    travel_to(Time.zone.local(DAY.year, DAY.month, DAY.day, hour, 0, 0), &block)
  end

  def export_xlsx(hour: 11)
    at(hour) do
      sign_in @admin
      get export_admin_stock_path
    end
    assert_response :success
    XlsxReader.new(response.body)
  end

  def data_rows(xlsx)
    xlsx.rows(Stock::ExcelExporter::SHEET_NAME)[1..].take_while { |row| row.any? }
  end

  def row_for(xlsx, name)
    data_rows(xlsx).find { |row| row.first == name } || flunk("no hay fila para #{name}")
  end

  def column(name) = HEADERS.index(name)

  test "downloads a real .xlsx named with the local date, with the Control de Stock sheet and headers" do
    xlsx = export_xlsx

    assert_equal "PK", response.body.byteslice(0, 2), "un .xlsx es un zip"
    assert_equal Stock::ExcelExporter::CONTENT_TYPE, response.media_type
    assert_match %r{attachment; filename="HANS_Control_Stock_2026-10-06\.xlsx"}, response.headers["Content-Disposition"]
    assert_equal ["Control de Stock"], xlsx.sheet_names
    assert_equal HEADERS, xlsx.rows("Control de Stock").first
    assert_match %r{Generado por HANS el 06/10/2026 11:00}, xlsx.rows("Control de Stock").last.first
  end

  test "exports every active stock item alphabetically, including sufficient and zero-minimum ones" do
    names = data_rows(export_xlsx).map(&:first)

    assert_equal ["Ábaco negativo", "Brownie export", "Crema sobrante", "Dulce sin mínimo", "Masa con lote"], names
    assert_not_includes names, "Zeta inactiva"
  end

  test "values match exactly what the stock panel computes" do
    xlsx = export_xlsx
    snapshot = at(11) { Stock::Availability.for_item(@brownie_item, now: Time.current) }
    row = row_for(xlsx, "Brownie export")

    assert_equal "kg", row[column("Unidad")]
    assert_equal snapshot.physical_quantity, row[column("Stock físico")]
    assert_equal 10, row[column("Stock físico")]
    assert_equal 3, row[column("Salidas pendientes hoy")]
    assert_equal 2, row[column("Comprometido futuro")]
    assert_equal 5, row[column("Stock disponible")]
    assert_equal snapshot.available_quantity, row[column("Stock disponible")]
    assert_equal 8, row[column("Stock mínimo")]
    assert_equal 3, row[column("Producir")]
    assert_equal 12, row_for(xlsx, "Masa con lote")[column("Producir")], "con lote usa la sugerencia en tandas del panel"
    assert_equal 0, row_for(xlsx, "Crema sobrante")[column("Producir")]
  end

  test "after the 13:00 cutoff today's dispatch is already in physical, so nothing is pending" do
    row = row_for(export_xlsx(hour: 14), "Brownie export")

    assert_equal 7, row[column("Stock físico")]
    assert_equal 0, row[column("Salidas pendientes hoy")]
    assert_equal 5, row[column("Stock disponible")]
  end

  test "negative stock is preserved as a negative number" do
    row = row_for(export_xlsx, "Ábaco negativo")

    assert_equal(-4, row[column("Stock físico")])
    assert_equal(-4, row[column("Stock disponible")])
    assert_equal 6, row[column("Producir")]
  end

  test "numbers are real numeric cells, count and notes are empty and difference is a formula" do
    xlsx = export_xlsx
    cells = xlsx.cells("Control de Stock")[1]
    xml = xlsx.xml("Control de Stock")

    %w[Stock\ físico Salidas\ pendientes\ hoy Comprometido\ futuro Stock\ disponible Stock\ mínimo Producir].each do |header|
      assert_includes [nil, "n"], cells[column(header)].type, "#{header} debe ser número, no texto"
      assert_kind_of Numeric, cells[column(header)].value
    end
    assert_nil data_rows(xlsx).first[column("Conteo real")]
    assert_nil data_rows(xlsx).first[column("Observaciones")]

    formulas = xml.xpath("//sheetData/row/c[starts-with(@r,'J')]/f").map(&:text)
    assert_equal 5, formulas.size
    assert_equal %(IF(I2="","",I2-C2)), formulas.first
    assert_equal %(IF(I6="","",I6-C6)), formulas.last
  end

  test "difference has red/green conditional formatting, filters and a frozen header" do
    xml = export_xlsx.xml("Control de Stock")

    rules = xml.xpath("//conditionalFormatting[@sqref='J2:J6']/cfRule/formula").map(&:text)
    assert_equal [%(AND($I2<>"",$J2<>0)), %(AND($I2<>"",$J2=0))], rules
    assert_equal "A1:K6", xml.at_xpath("//autoFilter")["ref"]
    assert_equal "frozen", xml.at_xpath("//sheetView/pane")["state"]
    assert_equal "A2", xml.at_xpath("//sheetView/pane")["topLeftCell"]
  end

  test "admin and production can export; customers and visitors cannot" do
    [@admin, @production].each do |user|
      at(11) { sign_in user; get export_admin_stock_path }
      assert_response :success
      sign_out :user
    end

    at(11) { sign_in @customer_user; get export_admin_stock_path }
    assert_redirected_to dashboard_path
    sign_out :user

    at(11) { get export_admin_stock_path }
    assert_redirected_to new_user_session_path
  end

  test "the panel shows the export button" do
    at(11) { sign_in @admin; get admin_stock_path }
    assert_select "a#export-stock-xlsx[href=?]", export_admin_stock_path, text: "Exportar stock a Excel"
  end

  test "exporting does not change the database" do
    # Como en el uso real: el botón está en el panel, que ya hizo su conciliación al abrirse.
    at(14) { sign_in @admin; get admin_stock_path }
    snapshot = lambda do
      [StockMovement.count, StockItem.order(:id).pluck(:id, :quantity, :minimum_quantity, :production_batch_size, :active, :updated_at),
       Order.order(:id).pluck(:id, :updated_at, :total_cents), OrderItem.count, Payment.count, RetailOrder.count, Product.maximum(:updated_at)]
    end
    before = snapshot.call

    at(14) { get export_admin_stock_path }
    assert_response :success
    at(15) { get export_admin_stock_path }
    assert_response :success

    assert_equal before, snapshot.call
  end
end
