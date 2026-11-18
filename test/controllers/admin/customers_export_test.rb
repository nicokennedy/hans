require "test_helper"
require_relative "../../support/xlsx_reader"

class Admin::CustomersExportTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = User.create!(email: "export-admin@example.com", password: "password123", role: "admin")
    @customer = Customer.create!(name: "Café Export", address: "Av. Colón 2345", active: true)
  end

  test "admins see the button and download the Excel" do
    sign_in @admin
    get admin_customers_path
    assert_select "a[href=?]", export_admin_customers_path, text: "Exportar clientes"

    get export_admin_customers_path
    assert_response :success
    assert_equal Customers::AddressExport::CONTENT_TYPE, response.media_type
    assert_match(/attachment; filename="HANS_Clientes_Direcciones_\d{4}-\d{2}-\d{2}\.xlsx"/, response.headers["Content-Disposition"])
    assert_includes XlsxReader.new(response.body).rows("Clientes").map { |r| r[1] }, "Café Export"
  end

  test "only admins can export" do
    customer_user = User.create!(email: "export-customer@example.com", password: "password123", role: "customer", customer: @customer)
    { User.create!(email: "export-prod@example.com", password: "password123", role: "production") => admin_production_index_path,
      User.create!(email: "export-driver@example.com", password: "password123", role: "driver") => reparto_root_path,
      customer_user => dashboard_path }.each do |user, fallback|
      sign_in user
      get export_admin_customers_path
      assert_redirected_to fallback
    end
  end

  test "exporting writes nothing" do
    sign_in @admin
    assert_no_difference -> { Customer.maximum(:updated_at).to_f } do
      get export_admin_customers_path
    end
  end
end
