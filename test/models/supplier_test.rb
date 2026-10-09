require "test_helper"
require_relative "../support/finance_helpers"

class SupplierTest < ActiveSupport::TestCase
  include FinanceHelpers

  def setup
    setup_finance
  end

  test "el nombre es obligatorio; el resto de los datos son opcionales" do
    assert_not Supplier.new(name: "  ").valid?
    supplier = Supplier.create!(name: " Molino S.A. ", tax_id: "", email: "", phone: "11 5555", address: "Calle 1", notes: "")
    assert_equal "Molino S.A.", supplier.name
    assert_nil supplier.tax_id
    assert_nil supplier.email
    assert supplier.active?
  end

  test "CUIT con formato válido, sin guiones al guardar, y no repetido" do
    supplier = Supplier.create!(name: "Con CUIT", tax_id: "30-12345678-9")
    assert_equal "30123456789", supplier.tax_id

    assert_not Supplier.new(name: "Mal CUIT", tax_id: "123").valid?
    assert_not Supplier.new(name: "CUIT repetido", tax_id: "30123456789").valid?
    assert_not Supplier.new(name: "CUIT repetido", tax_id: "30-12345678-9").valid?
    assert Supplier.new(name: "Sin CUIT 1").valid?
    Supplier.create!(name: "Sin CUIT 2")
    assert Supplier.new(name: "Sin CUIT 3").valid?, "varios proveedores sin CUIT son válidos"
  end

  test "email con formato válido" do
    assert_not Supplier.new(name: "X", email: "no-es-email").valid?
    assert Supplier.new(name: "X", email: "ventas@molino.com").valid?
  end

  test "búsqueda por nombre, CUIT, email o teléfono, y filtro de activos" do
    a = Supplier.create!(name: "Lácteos del Sur", tax_id: "20111111112", email: "lacteos@sur.com", phone: "2235551111")
    b = Supplier.create!(name: "Frutas Mar del Plata", active: false)

    assert_includes Supplier.search("Lácteos"), a
    assert_includes Supplier.search("2011111"), a
    assert_includes Supplier.search("sur.com"), a
    assert_includes Supplier.search("5551111"), a
    assert_not_includes Supplier.search("Lácteos"), b
    assert_equal Supplier.count, Supplier.search("").count
    assert_includes Supplier.active, a
    assert_not_includes Supplier.active, b
    assert_equal [], Supplier.search("%").to_a, "los comodines de LIKE se escapan"
  end

  test "un proveedor con movimientos no se puede borrar, solo desactivar; sin movimientos sí" do
    make_purchase(100)
    assert_not @supplier.deletable?
    assert_not @supplier.destroy
    assert Supplier.exists?(@supplier.id)

    @supplier.update!(active: false)
    assert_not @supplier.reload.active?
    assert_equal 1, @supplier.obligations.count, "el historial se conserva"

    assert @other_supplier.deletable?
    assert @other_supplier.destroy
  end

  test "con pagos solamente (sin compras) tampoco se puede borrar" do
    pay(100, obligations: [])
    assert_not @supplier.reload.deletable?
  end

  test "los saldos se calculan desde obligaciones y pagos reales (no hay columna de saldo)" do
    assert_not Supplier.column_names.any? { |c| c.include?("balance") || c.include?("saldo") }
    a = make_purchase(100)
    make_purchase(50)
    pay(120, obligations: Finance::Distribution.pending_obligations(@supplier).to_a)
    pay(40, allocations: {})

    @supplier.reload
    assert_equal pesos(30), @supplier.pending_cents
    assert_equal pesos(40), @supplier.advance_cents
    assert_equal(-pesos(10), @supplier.net_balance_cents)
    assert_equal 0, Supplier.new.pending_cents
  end

  test "los mensajes de validación del módulo están en español (sin 'Translation missing')" do
    invalid = [
      Supplier.new(name: "", tax_id: "1", email: "x"), PurchaseItem.new, Purchase.new(discount_cents: -1), ExpenseCategory.new, Obligation.new, OutgoingPayment.new,
      OutgoingPaymentApplication.new, ExpenseRecurrence.new(frequency: "x", max_occurrences: 0, due_days: -1), Expense.new, AdministrationAttachment.new
    ]
    messages = invalid.flat_map { |record| record.tap(&:valid?).errors.full_messages }

    assert messages.size > 25
    assert_empty messages.grep(/ranslation missing|\bes\./), "mensajes sin traducir: #{messages.grep(/ranslation missing/).first(3).inspect}"
    assert_includes messages, "El nombre no puede estar en blanco"
    assert_includes messages, "La descripción no puede estar en blanco"
    assert_includes messages, "La cantidad no es un número"
    assert_includes messages, "El CUIT/CUIL no tiene un formato válido (11 dígitos)"
  end
end
