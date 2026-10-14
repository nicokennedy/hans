require "test_helper"
require_relative "../../support/retail_helpers"
require_relative "../../support/xlsx_reader"

class Admin::RetailOrdersExportTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include RetailHelpers

  setup do
    setup_retail
    @production_user = User.create!(email: "retail-exp-prod-#{rand(1_000_000)}@example.com", password: "password123", role: "production")
    @customer_user = User.create!(email: "retail-exp-cust-#{rand(1_000_000)}@example.com", password: "password123", role: "customer", customer: @customer)
  end

  def download(params = {})
    get export_admin_retail_orders_path(params)
    assert_response :success
    XlsxReader.new(response.body)
  end

  def summary_names(xlsx)
    xlsx.rows("Resumen de pedidos").drop(1).map { |row| row[3] }
  end

  def seed_orders
    today = Date.current
    @a = create_retail(attributes: { buyer_name: "Ana Retiro", delivery_date: (today + 1).iso8601, delivery_kind: "pickup" }, items: [product_row(@mini, 2, "500"), manual_row("Torta A", 1, "100")])
    @b = create_retail(attributes: { buyer_name: "Beto Delivery", delivery_date: (today + 5).iso8601, delivery_kind: "delivery" }, items: [product_row(@mini, 4, "500")])
    @c = create_retail(attributes: { buyer_name: "Carla Pasada", delivery_date: (today - 10).iso8601 }, items: [product_row(@torta, 1, "4.000")])
    pay_retail(@b, "1.000")
    pay_retail(@c, "4.000")
    Retail::ChangeStatus.call(order: @c, to_status: "delivered", user: @admin)
    Retail::ChangeStatus.call(order: @a, to_status: "canceled", user: @admin)
  end

  test "el listado tiene el botón Exportar Excel y arrastra los filtros aplicados (sin la página)" do
    sign_in @admin
    get admin_retail_orders_path(buyer: "ana", status: "pending", kind: "pickup", payment_status: "pending", date_from: "2026-10-01", date_to: "2026-10-31", page: "1")

    assert_select "a#export-retail-xlsx", text: "Exportar Excel"
    href = css_select("a#export-retail-xlsx").first["href"]
    assert_match %r{\A/admin/retail_orders/export\?}, href
    %w[buyer=ana status=pending kind=pickup payment_status=pending date_from=2026-10-01 date_to=2026-10-31].each { |part| assert_includes href, part }
    assert_not_includes href, "page="
  end

  test "sin filtros exporta todos los pedidos como un .xlsx descargable" do
    seed_orders
    sign_in @admin

    get export_admin_retail_orders_path
    assert_response :success
    assert_equal Retail::ExcelExporter::CONTENT_TYPE, response.media_type
    assert_match(/\Aattachment; filename="pedidos_minoristas_#{Date.current.iso8601}\.xlsx"/, response.headers["Content-Disposition"])
    assert_equal "PK", response.body.byteslice(0, 2)

    xlsx = XlsxReader.new(response.body)
    assert_equal ["Detalle de productos", "Resumen de pedidos"], xlsx.sheet_names
    assert_equal ["Carla Pasada", "Ana Retiro", "Beto Delivery"], summary_names(xlsx), "ordenado por fecha de entrega"
    assert_equal 4, xlsx.rows("Detalle de productos").drop(1).size, "una fila por ítem (2 + 1 + 1)"
  end

  test "cada filtro del listado se respeta en la exportación" do
    seed_orders
    today = Date.current
    sign_in @admin

    assert_equal ["Ana Retiro"], summary_names(download(buyer: "ana"))
    assert_equal ["Beto Delivery"], summary_names(download(kind: "delivery"))
    assert_equal ["Ana Retiro"], summary_names(download(status: "canceled"))
    assert_equal ["Carla Pasada"], summary_names(download(status: "delivered"))
    assert_equal ["Carla Pasada"], summary_names(download(payment_status: "paid"))
    assert_equal ["Beto Delivery"], summary_names(download(payment_status: "partial"))
    assert_equal ["Ana Retiro"], summary_names(download(payment_status: "pending"))
    assert_equal ["Ana Retiro"], summary_names(download(date_from: (today + 1).iso8601)), "un solo día"
    assert_equal ["Ana Retiro", "Beto Delivery"], summary_names(download(date_from: today.iso8601, date_to: (today + 6).iso8601)), "rango"
    assert_equal ["Carla Pasada"], summary_names(download(date_to: (today - 1).iso8601)), "hasta"
    assert_equal ["Beto Delivery"], summary_names(download(kind: "delivery", status: "pending", payment_status: "partial", buyer: "beto")), "filtros combinados"
    assert_empty summary_names(download(buyer: "nadie"))

    # el detalle también se filtra por pedido
    detail = download(buyer: "ana").rows("Detalle de productos").drop(1)
    assert_equal ["Ana Retiro"], detail.map { |r| r[4] }.uniq
    assert_equal 2, detail.size
  end

  test "ignora la página y filtros inválidos o manipulados" do
    seed_orders
    sign_in @admin

    assert_equal 3, summary_names(download(page: "5")).size
    assert_equal 3, summary_names(download(status: "x'; DROP TABLE retail_orders;--", kind: "zzz", payment_status: ["a"], date_from: "no-es-fecha", buyer: nil)).size
    assert_equal 3, RetailOrder.count
  end

  test "respeta el contexto del listado al exportar desde la pantalla filtrada" do
    seed_orders
    sign_in @admin
    get admin_retail_orders_path(kind: "delivery")
    get css_select("a#export-retail-xlsx").first["href"]

    assert_equal ["Beto Delivery"], summary_names(XlsxReader.new(response.body))
  end

  test "solo admin: sin sesión, cliente mayorista y producción no reciben el archivo" do
    seed_orders

    [nil, @customer_user, @production_user].each do |user|
      sign_in user if user
      get export_admin_retail_orders_path
      assert_response :redirect, "#{user&.role || 'anónimo'} no debería descargar"
      assert_not_equal Retail::ExcelExporter::CONTENT_TYPE, response.media_type
      sign_out user if user
    end
  end

  test "la exportación no cambia pedidos, pagos, stock ni producción" do
    seed_orders
    sign_in @admin
    snapshot = lambda do
      [RetailOrder.pluck(:id, :updated_at, :status, :total_cents, :amount_paid_cents), RetailOrderPayment.pluck(:id, :updated_at, :voided_at), RetailOrderItem.pluck(:id, :updated_at),
       RetailOrderStatusChange.count, StockMovement.count, StockItem.pluck(:id, :quantity), Order.count, Payment.count, CustomerPayment.count,
       Product.pluck(:id, :price_cents), ProductionDaySheet.for(Date.current + 1).rows, ProductionDaySheet.for(Date.current + 5).rows]
    end
    before = snapshot.call

    download
    download(buyer: "ana")

    assert_equal before, snapshot.call
  end
end
