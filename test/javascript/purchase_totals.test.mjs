import test from "node:test"
import assert from "node:assert/strict"
import { computePurchase, lineSubtotalCents, parseQuantityThousandths, parseSignedPesos } from "../../app/javascript/purchase_totals.js"

test("cantidades exactas en milésimas, con decimales de coma o punto", () => {
  assert.equal(parseQuantityThousandths("2,5"), 2500n)
  assert.equal(parseQuantityThousandths("2.5"), 2500n)
  assert.equal(parseQuantityThousandths("25"), 25000n)
  assert.equal(parseQuantityThousandths("0,125"), 125n)
  assert.equal(parseQuantityThousandths("1.250,5"), 1250500n)
  assert.equal(parseQuantityThousandths("1250"), 1250000n)
  assert.equal(parseQuantityThousandths("1.250.000"), 1250000000n)
})

test("cantidades ambiguas o inválidas se rechazan (igual que en el servidor)", () => {
  ;["", "abc", "1.250", "1,250", "-1", "1.2345", "1,5kg", "1,2,3x"].forEach((text) => assert.equal(parseQuantityThousandths(text), null, text))
})

test("subtotal = cantidad x precio, mitad hacia arriba, sin floats", () => {
  assert.equal(lineSubtotalCents(25000n, 85050), 2_126_250)
  assert.equal(lineSubtotalCents(2500n, 520000), 1_300_000)
  assert.equal(lineSubtotalCents(100n, 3000), 300, "0,1 x $30")
  assert.equal(lineSubtotalCents(200n, 3000), 600, "0,2 x $30")
  assert.equal(lineSubtotalCents(1500n, 4533), 6800, "6799,5 -> 6800")
  assert.equal(lineSubtotalCents(5n, 100), 1, "0,005 x $1")
  assert.equal(lineSubtotalCents(1_000_000_000n, 999_999_999), 999_999_999_000_000, "no pierde precisión con importes enormes (cantidad 1.000.000 x $9.999.999,99)")
})

test("importes con signo para otros ajustes", () => {
  assert.equal(parseSignedPesos("-50"), -5000)
  assert.equal(parseSignedPesos("1.500"), 150000)
  assert.equal(parseSignedPesos("x"), null)
})

test("compra completa: ítems, descuento, impuestos y ajustes", () => {
  const r = computePurchase({
    rows: [{ quantity: "25", price: "850,50" }, { quantity: "2,5", price: "5.200" }, { quantity: "", price: "" }],
    discount: "1.000", taxes: "4.200", adjustments: "-50"
  })
  assert.deepEqual(r.lines.map((l) => l.subtotal), [2_126_250, 1_300_000, 0])
  assert.equal(r.subtotal, 3_426_250)
  assert.equal(r.total, 3_426_250 - 100_000 + 420_000 - 5_000)
  assert.deepEqual(r.errors, [])
})

test("errores: cantidad o precio inválidos, importes inválidos y total no positivo", () => {
  assert.ok(computePurchase({ rows: [{ quantity: "abc", price: "10" }] }).errors.some((e) => /Ítem 1: cantidad inválida/.test(e)))
  assert.ok(computePurchase({ rows: [{ quantity: "1", price: "x" }] }).errors.some((e) => /precio inválido/.test(e)))
  assert.ok(computePurchase({ rows: [{ quantity: "1", price: "10" }], discount: "zz" }).errors.some((e) => /descuento/i.test(e)))
  assert.ok(computePurchase({ rows: [{ quantity: "1", price: "10" }], discount: "999" }).errors.some((e) => /mayor a cero/.test(e)))
  assert.deepEqual(computePurchase({ rows: [{ quantity: "", price: "" }] }).errors, [], "una fila vacía no es un error")
})
