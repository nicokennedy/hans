require "test_helper"
require_relative "../../support/finance_helpers"

class Finance::PurchasesTest < ActiveSupport::TestCase
  include FinanceHelpers

  def setup
    setup_finance
  end

  def save_purchase(items:, totals: {}, supplier: @supplier, purchase: nil, attributes: {}, **extra)
    Finance::SavePurchase.call(
      user: @admin, purchase: purchase,
      attributes: { supplier_id: supplier&.id, accrual_on: Date.new(2026, 10, 1), due_on: Date.new(2026, 10, 31), document_type: "factura_a", document_number: "0001-00001234", notes: "Compra semanal" }.merge(attributes),
      totals: { discount_cents: 0, taxes_cents: 0, adjustments_cents: 0 }.merge(totals), items: items, **extra
    )
  end

  def item(description, quantity, unit, unit_price_cents, id: nil)
    { id: id, description: description, quantity: BigDecimal(quantity.to_s), unit: unit, unit_price_cents: unit_price_cents }
  end

  test "compra con múltiples ítems: subtotales, total y una sola obligación" do
    result = save_purchase(items: [item("Harina 000", "25", "kg", 85_050), item("Manteca", "2.5", "kg", 520_000), item("Huevos", "30", "un", 18_333)])

    assert result.ok?, result.errors.inspect
    purchase = result.record.reload
    assert_equal [2_126_250, 1_300_000, 549_990], purchase.items.map(&:subtotal_cents), "cantidad x precio, exacto"
    assert_equal 3_976_240, purchase.subtotal_cents
    assert_equal 3_976_240, purchase.total_cents
    obligation = purchase.obligation
    assert_equal 3_976_240, obligation.amount_cents
    assert_equal @supplier, obligation.supplier
    assert_equal "0001-00001234", obligation.document_number
    assert_equal Date.new(2026, 10, 31), obligation.due_on
    assert_equal 1, Obligation.where(source: purchase).count
    assert_equal :pending, obligation.status
  end

  test "descuento, impuestos y otros ajustes concilian el importe final sin perder el detalle" do
    result = save_purchase(items: [item("Azúcar", "10", "kg", 200_000)], totals: { discount_cents: 100_000, taxes_cents: 420_000, adjustments_cents: -5_000 })

    assert result.ok?
    purchase = result.record.reload
    assert_equal 2_000_000, purchase.subtotal_cents
    assert_equal 2_000_000 - 100_000 + 420_000 - 5_000, purchase.total_cents
    assert_equal purchase.total_cents, purchase.obligation.amount_cents
    assert_equal 1, purchase.items.count
  end

  test "cálculos exactos, sin floats: 0,1 + 0,2 y redondeo de centavos" do
    result = save_purchase(items: [item("A", "0.1", "kg", 3_000), item("B", "0.2", "kg", 3_000), item("C", "3", "un", 3_333)])

    assert result.ok?
    assert_equal [300, 600, 9_999], result.record.items.map(&:subtotal_cents)
    assert_equal 10_899, result.record.total_cents
    assert_equal 6_800, Finance::Money.line_subtotal_cents(BigDecimal("1.5"), 4_533), "6799,5 -> 6800 (mitad hacia arriba)"
    assert_equal 1, Finance::Money.line_subtotal_cents(BigDecimal("0.005"), 100)
  end

  test "parseo de cantidades y de pesos" do
    q = ->(text) { Finance::Money.parse_quantity(text) }
    assert_equal BigDecimal("2.5"), q.("2,5")
    assert_equal BigDecimal("2.5"), q.("2.5")
    assert_equal BigDecimal("1250.5"), q.("1.250,5")
    assert_equal BigDecimal("1250"), q.("1250")
    assert_equal BigDecimal("1250000"), q.("1.250.000")
    assert_nil q.("1.250"), "ambiguo: 1,25 o 1250"
    assert_nil q.("1,250"), "ambiguo: 1,25 o 1250"
    assert_equal BigDecimal("0.125"), q.("0.125")
    assert_equal BigDecimal("1250.5"), q.("1250,5")
    assert_equal BigDecimal("0.125"), q.("0,125")
    assert_equal BigDecimal("12"), q.("12")
    ["", "abc", "1,2,3x", "-1", "1.2345", "1,5kg"].each { |text| assert_nil q.(text), text.inspect }
    assert_equal "2,5", Finance::Money.format_quantity(BigDecimal("2.5"))
    assert_equal "12", Finance::Money.format_quantity(BigDecimal("12.000"))
  end

  test "validaciones: proveedor, ítems, cantidad, unidad, precio y total positivo" do
    assert_not save_purchase(items: [item("X", 1, "un", 100)], supplier: nil).ok?
    assert_not save_purchase(items: []).ok?
    bad = save_purchase(items: [item("", 1, "un", 100), item("Y", 0, "kg", 100), item("Z", 1, "parsec", 100), item("W", 1, "un", -5)])
    assert_not bad.ok?
    assert_match(/Ítem 1/, bad.errors.join)
    assert_match(/Ítem 2/, bad.errors.join)
    assert_match(/Ítem 3/, bad.errors.join)
    assert_match(/Ítem 4/, bad.errors.join)
    assert_not save_purchase(items: [item("Gratis", 1, "un", 0)]).ok?, "total 0 no es una compra"
    assert_not save_purchase(items: [item("X", 1, "un", 100)], totals: { discount_cents: 500 }).ok?, "descuento mayor al subtotal deja total negativo"
    assert_not save_purchase(items: [item("X", 1, "un", 100)], attributes: { due_on: Date.new(2026, 9, 1) }).ok?, "vence antes de la compra"
    assert_not save_purchase(items: [item("X", 1, "un", 100)], attributes: { document_type: "inventado" }).ok?
    assert_equal 0, Purchase.count
    assert_equal 0, Obligation.count
  end

  test "todo o nada: si falla algo no queda ni compra, ni ítems ni obligación" do
    assert_no_difference ["Purchase.count", "PurchaseItem.count", "Obligation.count"] do
      assert_not save_purchase(items: [item("Bien", 1, "un", 100), item("Mal", 0, "un", 100)]).ok?
    end
  end

  test "editar: actualiza ítems existentes conservando su id, agrega y quita filas, y recalcula el total" do
    purchase = save_purchase(items: [item("Harina", 10, "kg", 100_000), item("Azúcar", 5, "kg", 50_000)]).record
    harina, azucar = purchase.items.to_a

    result = save_purchase(purchase: purchase.reload, items: [item("Harina 0000", 12, "kg", 110_000, id: harina.id), item("Levadura", 1, "kg", 90_000)],
                           attributes: { document_number: "0001-00009999" })

    assert result.ok?, result.errors.inspect
    purchase.reload
    assert_equal harina.id, purchase.items.first.id, "el ítem editado conserva su registro"
    assert_equal "Harina 0000", purchase.items.first.description
    assert_not PurchaseItem.exists?(azucar.id), "la fila quitada se elimina"
    assert_equal %w[Harina\ 0000 Levadura], purchase.items.map(&:description)
    assert_equal 1_320_000 + 90_000, purchase.total_cents
    assert_equal purchase.total_cents, purchase.obligation.amount_cents
    assert_equal "0001-00009999", purchase.obligation.document_number
    assert_equal 1, Obligation.count
  end

  test "no se puede editar una compra dejando un total menor a lo ya pagado" do
    purchase = save_purchase(items: [item("X", 1, "un", pesos(100))]).record
    pay(60)

    assert_not save_purchase(purchase: purchase.reload, items: [item("X", 1, "un", pesos(50), id: purchase.items.first.id)]).ok?
    assert_equal pesos(100), purchase.reload.obligation.amount_cents
    assert save_purchase(purchase: purchase, items: [item("X", 1, "un", pesos(80), id: purchase.items.first.id)]).ok?
    assert_equal pesos(20), purchase.reload.obligation.balance_cents
  end

  test "no se puede cambiar el proveedor de una compra con pagos imputados" do
    purchase = save_purchase(items: [item("X", 1, "un", pesos(100))]).record
    pay(10)

    result = save_purchase(purchase: purchase.reload, items: [item("X", 1, "un", pesos(100), id: purchase.items.first.id)], supplier: @other_supplier)
    assert_not result.ok?
    assert_match(/ya tiene pagos imputados/, result.errors.join)
  end

  test "pagar al cargar la compra: pago total, parcial y excedente rechazado" do
    full = save_purchase(items: [item("X", 1, "un", pesos(100))], pay_now: { amount_cents: pesos(100), payment_method: "cash", reference: "R1" })
    assert full.ok?
    assert_equal :paid, full.record.obligation.status
    assert_equal 1, OutgoingPayment.count

    partial = save_purchase(items: [item("Y", 1, "un", pesos(100))], pay_now: { amount_cents: pesos(30), payment_method: "bank_transfer" })
    assert partial.ok?
    assert_equal :partial, partial.record.obligation.status
    assert_equal pesos(70), partial.record.obligation.balance_cents

    assert_no_difference ["Purchase.count", "OutgoingPayment.count", "Obligation.count"] do
      over = save_purchase(items: [item("Z", 1, "un", pesos(100))], pay_now: { amount_cents: pesos(101), payment_method: "cash" })
      assert_not over.ok?
      assert_match(/Pago:/, over.errors.join)
    end
  end

  test "los ítems guardan el historial completo y el vínculo futuro con una materia prima queda vacío" do
    purchase = save_purchase(items: [item("Harina", 10, "kg", 100_000)]).record
    saved = purchase.items.first

    assert_equal BigDecimal("10"), saved.quantity
    assert_equal "kg", saved.unit
    assert_equal 100_000, saved.unit_price_cents
    assert_nil saved.raw_material_id
    assert_includes PurchaseItem.column_names, "raw_material_id"
    assert saved.valid?
  end

  test "crear, editar y pagar una compra NO modifica stock, materias primas, costos ni recetas" do
    raw = RawMaterial.create!(name: "Harina 000", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg", supplier: "Molino")
    preparation = Preparation.create!(name: "Masa", yield_quantity: 1, yield_unit: "kg")
    preparation.recipe_components.create!(component: raw, quantity: 1, unit: "kg")
    product = Product.create!(name: "Alfajor", category: Category.create!(name: "C#{rand(100_000)}", position: 1, active: true), price_cents: 500, cost_cents: 200, active: true, position: 1)
    StockItem.create!(stockable: product, active: true, quantity: 7, minimum_quantity: 3, stock_tracking_started_on: Date.new(2026, 1, 1))
    before = untouchable_snapshot

    purchase = save_purchase(items: [item("Harina 000", 100, "kg", 150_000), item("Manteca", 20, "kg", 700_000)], pay_now: { amount_cents: pesos(50), payment_method: "cash" }).record
    save_purchase(purchase: purchase.reload, items: [item("Harina 000", 120, "kg", 160_000, id: purchase.items.first.id)])
    pay(100)

    assert_equal before, untouchable_snapshot, "ni stock, ni materias primas, ni costos, ni recetas"
    assert_equal 100_000, raw.reload.purchase_price_cents
    assert_equal 0, RawMaterialCostChange.count
  end
end
