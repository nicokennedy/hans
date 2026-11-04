require "test_helper"
require_relative "../../support/retail_helpers"
require_relative "../../support/xlsx_reader"

# Confirmar / rechazar pedidos minoristas desde Admin, filtros por origen y confirmación,
# exportación y la sección "por confirmar" de la hoja de producción.
class Admin::RetailOrderConfirmationTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include RetailHelpers

  setup do
    setup_retail
    @production = User.create!(email: "retail-conf-production@example.com", password: "password123", role: "production")
    @customer_user = User.create!(email: "retail-conf-customer@example.com", password: "password123", role: "customer", customer: @customer)
    @date = Date.new(2026, 10, 27)
    @manual = create_retail(attributes: { buyer_name: "Ana Manual", delivery_date: @date.iso8601 }, items: [product_row(@mini, 3, "500")])
    @web = Retail::SaveOrder.call(order: RetailOrder.new, attributes: base_attributes(buyer_name: "Beto Web", delivery_date: @date.iso8601),
                                  items: [product_row(@mini, 5, "500")], user: nil, source: "store", request_token: "tok-1").record
  end

  test "admin confirms an awaiting order from its page" do
    sign_in @admin
    get admin_retail_order_path(@web)
    assert_select "#retail-confirmation-status", text: "Pendiente de confirmación"
    assert_select "form[action=?] button", confirm_admin_retail_order_path(@web), text: "Confirmar pedido"
    assert_select "form[action=?] input[name=reason][required]", reject_admin_retail_order_path(@web)

    post confirm_admin_retail_order_path(@web, status: "pending")
    assert_redirected_to admin_retail_order_path(@web, status: "pending")
    assert @web.reload.confirmation_confirmed?
    assert_equal @admin, @web.confirmed_by

    follow_redirect!
    assert_select "#retail-confirmation-status", text: "Confirmado"
    assert_select "#retail-confirmation-history", text: /Pendiente de confirmación → Confirmado/
    assert_select "form[action=?]", confirm_admin_retail_order_path(@web), count: 0
  end

  test "a second confirm shows an error and changes nothing" do
    sign_in @admin
    post confirm_admin_retail_order_path(@web)
    post confirm_admin_retail_order_path(@web)

    assert_equal "El pedido ya está confirmado.", flash[:alert]
    assert_equal 1, @web.retail_order_confirmation_changes.count
  end

  test "admin rejects with a reason; without one it is refused" do
    sign_in @admin
    post reject_admin_retail_order_path(@web), params: { reason: "" }
    assert_equal "Indicá el motivo del rechazo.", flash[:alert]
    assert @web.reload.confirmation_awaiting?

    post reject_admin_retail_order_path(@web), params: { reason: "Fuera de zona" }
    assert @web.reload.confirmation_rejected?
    follow_redirect!
    assert_select "#retail-confirmation", text: /Pedido rechazado.*Fuera de zona/m
  end

  test "only admins can confirm or reject" do
    [@production, @customer_user].each do |user|
      sign_in user
      post confirm_admin_retail_order_path(@web)
      post reject_admin_retail_order_path(@web), params: { reason: "x" }
      sign_out :user
    end
    post confirm_admin_retail_order_path(@web)
    assert_redirected_to new_user_session_path

    assert @web.reload.confirmation_awaiting?
    assert_equal 0, @web.retail_order_confirmation_changes.count
  end

  test "the list shows origin and confirmation and filters by both, keeping the other filters" do
    sign_in @admin
    get admin_retail_orders_path
    assert_select "tbody tr", count: 2
    assert_select "tbody tr", text: /Beto Web.*Tienda online.*Pendiente de confirmación/m
    assert_select "tbody tr", text: /Ana Manual.*Manual.*Confirmado/m

    get admin_retail_orders_path(source: "store")
    assert_select "tbody tr", count: 1
    assert_select "tbody tr", text: /Beto Web/

    get admin_retail_orders_path(confirmation: "confirmed", buyer: "Ana")
    assert_select "tbody tr", count: 1
    assert_select "tbody tr", text: /Ana Manual/
    assert_select "a[href=?]", admin_retail_order_path(@manual, buyer: "Ana", confirmation: "confirmed")

    get admin_retail_orders_path(confirmation: "awaiting", buyer: "Ana")
    assert_select "tbody tr", count: 0

    get admin_retail_orders_path(source: "evil", confirmation: "drop")
    assert_select "tbody tr", count: 2
  end

  test "the export respects the new filters and carries origin and confirmation" do
    sign_in @admin
    get export_admin_retail_orders_path(confirmation: "awaiting")
    rows = XlsxReader.new(response.body).rows("Resumen de pedidos")

    assert_equal ["Origen", "Confirmación"], rows.first.last(2)
    assert_equal 2, rows.size
    assert_equal ["Beto Web", "Tienda online", "Pendiente de confirmación"], [rows[1][3], *rows[1].last(2)]
  end

  test "the production sheet lists awaiting orders apart and does not count them" do
    sign_in @production
    get admin_production_path(@date.iso8601)

    assert_response :success
    assert_select "#production-awaiting", text: /Por confirmar.*Beto Web.*5 × /m
    assert_select "#production-awaiting a", count: 0, message: "production no tiene acceso a pedidos minoristas"
    assert_equal 3, ProductionDaySheet.for(@date).rows.sum { |row| row[:total] }

    sign_out :user
    sign_in @admin
    post confirm_admin_retail_order_path(@web)
    get admin_production_path(@date.iso8601)
    assert_select "#production-awaiting", count: 0
    assert_equal 8, ProductionDaySheet.for(@date).rows.sum { |row| row[:total] }
  end

  test "manual orders created from admin are confirmed and show no confirmation actions" do
    sign_in @admin
    get admin_retail_order_path(@manual)

    assert_select "#retail-confirmation-status", text: "Confirmado"
    assert_select "#retail-confirmation", count: 0
    assert_select "form[action=?]", confirm_admin_retail_order_path(@manual), count: 0
  end
end
