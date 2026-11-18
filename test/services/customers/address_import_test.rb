require "test_helper"
require "caxlsx"

class Customers::AddressImportTest < ActiveSupport::TestCase
  HEADERS = Customers::AddressExport.headers

  setup do
    @aurora = Customer.create!(name: "Café Aurora", phone: "2235551234", address: nil, active: true)
    @esquina = Customer.create!(name: "Bar La Esquina", phone: "2235550000", address: "Güemes 3120", active: true)
    @viejo = Customer.create!(name: "Bar Viejo", address: "Rivadavia 100", active: false)
  end

  # Arma un Excel como el exportado, con las filas dadas como hashes { encabezado => valor }.
  def workbook(*rows, headers: HEADERS)
    package = Axlsx::Package.new
    package.workbook.add_worksheet(name: "Clientes") do |sheet|
      sheet.add_row headers
      rows.each { |row| sheet.add_row headers.map { |h| row[h] }, types: headers.map { |h| h.start_with?("ID") ? nil : :string } }
    end
    package.to_stream.read
  end

  def row(customer, **fields)
    { "ID cliente (NO MODIFICAR)" => customer.id, "Nombre" => customer.name, "Estado" => customer.active? ? "Activo" : "Inactivo",
      "Teléfono" => customer.phone }.merge(fields.transform_keys { |k| Customers::AddressFields::ALL.find { |f| f.column == k.to_s }&.header || k.to_s })
  end

  def import(data, apply: false)
    Customers::AddressImport.new(data).call(apply: apply)
  end

  test "the dry run lists old and new values and writes nothing" do
    data = workbook(row(@aurora, address: "Av. Colón 2345"), row(@esquina, address: "Güemes 3150"))

    result = import(data)

    assert_equal 2, result.changes.size
    change = result.changes.find { |c| c.customer_id == @esquina.id }
    assert_equal ["Güemes 3120", "Güemes 3150"], [change.from, change.to]
    assert_not result.applied
    assert_nil @aurora.reload.address
    assert_equal "Güemes 3120", @esquina.reload.address
  end

  test "apply updates only the address and keeps everything else" do
    updated_name = @aurora.name
    result = import(workbook(row(@aurora, address: "Av. Colón 2345").merge("Nombre" => "café aurora", "Teléfono" => "999", "Estado" => "Inactivo")), apply: true)

    assert result.applied
    @aurora.reload
    assert_equal "Av. Colón 2345", @aurora.address
    assert_equal updated_name, @aurora.name
    assert_equal "2235551234", @aurora.phone
    assert @aurora.active?
    assert_equal 2, result.warnings.size, "avisa que se ignoraron teléfono y estado"
  end

  test "empty cells never erase existing data" do
    result = import(workbook(row(@esquina, address: nil)), apply: true)

    assert_empty result.changes
    assert_equal "Güemes 3120", @esquina.reload.address
  end

  test "it never creates or deletes customers" do
    data = workbook(row(@aurora, address: "Av. Colón 2345"),
                    { "ID cliente (NO MODIFICAR)" => 999_999, "Nombre" => "Nuevo", "Dirección (calle y número)" => "Calle 1 123" })

    assert_no_difference -> { Customer.count } do
      result = import(data, apply: true)
      assert_match "No existe un cliente con ID 999999", result.errors.map(&:message).join
    end
  end

  test "duplicated ids are rejected entirely" do
    result = import(workbook(row(@aurora, address: "Av. Colón 2345"), row(@aurora, address: "Otra 123")), apply: true)

    assert_empty result.changes
    assert_equal 2, result.errors.size
    assert_nil @aurora.reload.address
  end

  test "a row whose name does not match the id is rejected" do
    result = import(workbook(row(@aurora, address: "Av. Colón 2345").merge("Nombre" => "Bar La Esquina")), apply: true)

    assert_empty result.changes
    assert_match "no coincide", result.errors.first.message
    assert_nil @aurora.reload.address
  end

  test "invalid ids and invalid addresses are reported" do
    data = workbook({ "ID cliente (NO MODIFICAR)" => "abc", "Dirección (calle y número)" => "Calle 1 123" },
                    row(@aurora, address: "Sin numero"),
                    row(@esquina, address: "=1+1"),
                    row(@viejo, address: "12"))

    result = import(data)

    assert_empty result.changes
    messages = result.errors.map(&:message).join(" | ")
    assert_match "no es un número de cliente", messages
    assert_match "no tiene número", messages
    assert_match "fórmula", messages
    assert_match "demasiado corta", messages
  end

  test "S/N addresses are accepted" do
    result = import(workbook(row(@aurora, address: "Ruta 88 km 5")), apply: true)
    assert_equal "Ruta 88 km 5", @aurora.reload.address

    result = import(workbook(row(@esquina, address: "Pasaje Los Olmos S/N")))
    assert_equal 1, result.changes.size
  end

  test "fields that do not exist yet in HANS are reported but not written" do
    skip "todas las columnas propuestas ya existen" if Customers::AddressFields.pending.empty?

    pending_field = Customers::AddressFields.pending.first
    value = { "province" => "Buenos Aires", "postal_code" => "7600" }.fetch(pending_field.column, "Algo válido 1")
    result = import(workbook(row(@aurora, pending_field.column.to_sym => value)), apply: true)

    assert_empty result.changes
    assert_equal 1, result.pending.size
  end

  test "province and postal code values are validated and normalized" do
    province = Customers::AddressFields::ALL.find { |f| f.column == "province" }
    postal = Customers::AddressFields::ALL.find { |f| f.column == "postal_code" }

    assert_equal ["Ciudad Autónoma de Buenos Aires", nil], Customers::AddressFields.normalize(province, "caba")
    assert_equal ["Córdoba", nil], Customers::AddressFields.normalize(province, "cordoba")
    assert Customers::AddressFields.normalize(province, "Narnia").last
    assert_equal ["7600", nil], Customers::AddressFields.normalize(postal, "7600")
    assert_equal ["B7600ABC", nil], Customers::AddressFields.normalize(postal, "b7600abc")
    assert Customers::AddressFields.normalize(postal, "76").last
  end

  test "the import is all or nothing if a customer changed after the dry run" do
    data = workbook(row(@aurora, address: "Av. Colón 2345"), row(@esquina, address: "Güemes 3150"))
    importer = Customers::AddressImport.new(data)

    # Simula que alguien editó la dirección entre la lectura y la escritura.
    importer.define_singleton_method(:write) do |changes|
      Customer.where(id: changes.last.customer_id).update_all(address: "Cambiada a mano 1")
      super(changes)
    end

    assert_raises(Customers::AddressImport::Aborted) { importer.call(apply: true) }
    assert_nil @aurora.reload.address, "no se aplica ningún cambio"
  end

  test "a file without the id column is refused" do
    assert_raises(Customers::AddressImport::Aborted) { import(workbook({ "Nombre" => "x" }, headers: ["Nombre", "Dirección (calle y número)"])) }
  end

  test "a file that is not an xlsx is refused" do
    assert_raises(Customers::XlsxRows::Error) { import("esto no es un excel") }
  end

  test "the exported file can be imported back without changes" do
    data = Customers::AddressExport.new(Customer.where(id: [@aurora.id, @esquina.id, @viejo.id])).call
    result = import(data)

    assert_empty result.changes
    assert_empty result.errors
    assert_empty result.warnings
  end
end
