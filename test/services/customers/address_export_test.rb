require "test_helper"
require_relative "../../support/xlsx_reader"

class Customers::AddressExportTest < ActiveSupport::TestCase
  setup do
    @active = Customer.create!(name: "Café Aurora", email: "aurora@example.com", phone: "223 555-1234", address: "Av. Colón 2345", address_unit: "Local 3",
                               city: "Mar del Plata", province: "Buenos Aires", postal_code: "7600",
                               delivery_instructions: "Timbre verde", payment_terms: "30 días", internal_notes: "Nota interna secreta", contact_name: "Zulema Contacto", active: true)
    @inactive = Customer.create!(name: "bar viejo", phone: nil, address: nil, active: false)
  end

  def export
    XlsxReader.new(Customers::AddressExport.new(Customer.where(id: [@active.id, @inactive.id])).call)
  end

  test "one row per customer, active and inactive, with the expected headers" do
    rows = export.rows("Clientes")

    assert_equal Customers::AddressExport.headers, rows.first
    assert_equal "ID cliente (NO MODIFICAR)", rows.first.first
    assert_equal 3, rows.size
    aurora = rows.find { |r| r[1] == "Café Aurora" }
    viejo = rows.find { |r| r[1] == "bar viejo" }
    assert_equal [@active.id, "Café Aurora", "Activo", "Av. Colón 2345", "Local 3", "Mar del Plata", "Buenos Aires", "7600", "Timbre verde"], aurora.first(9)
    assert_equal "223 555-1234", aurora.last
    assert_equal "Inactivo", viejo[2]
    assert viejo[3..].all?(&:blank?), "los datos que no existen quedan vacíos"
  end

  test "it includes no financial, access or internal data" do
    xml = export.parts.values.map { |body| body.dup.force_encoding(Encoding::UTF_8) }.join
    ["aurora@example.com", "30 días", "Nota interna secreta", "Zulema Contacto"].each do |secret|
      assert_not_includes xml, secret
    end
  end

  test "filters, frozen header and column widths are set" do
    sheet = export.parts.find { |name, body| name.start_with?("xl/worksheets/") && body.include?("autoFilter") }&.last
    assert sheet, "la hoja de clientes debe tener filtros"
    assert_match %r{<autoFilter ref=["']A1:J3["']}, sheet
    assert_match %r{<pane[^>]*ySplit="1"[^>]*state="frozen"|<pane[^>]*state="frozen"[^>]*ySplit="1"}, sheet
    assert_match %r{<col [^>]*width=}, sheet
  end

  test "it adds an instructions sheet" do
    reader = export
    assert_equal %w[Clientes Instrucciones], reader.sheet_names
    assert_match "NO MODIFICAR", reader.rows("Instrucciones").flatten.join(" ")
  end

  test "text that looks like a formula is exported as text" do
    @active.update!(address: "=HYPERLINK(\"http://x\")")
    sheet = export.parts.select { |name, _| name.start_with?("xl/worksheets/") }.values.join
    assert_no_match %r{<f>}, sheet
  end

  test "the instructions no longer mention pending fields" do
    assert_no_match "todavía no se guardan", export.rows("Instrucciones").flatten.join(" ")
  end
end
