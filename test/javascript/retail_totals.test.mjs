import test from "node:test"
import assert from "node:assert/strict"
import { computeRetail, parsePesos, parseQuantity } from "../../app/javascript/retail_totals.js"

test("cantidades enteras > 0; decimales, ceros y texto se rechazan", () => {
  assert.equal(parseQuantity("12"), 12)
  assert.equal(parseQuantity(" 3 "), 3)
  assert.equal(parseQuantity("0"), null)
  assert.equal(parseQuantity("1,5"), null)
  assert.equal(parseQuantity("-2"), null)
  assert.equal(parseQuantity("abc"), null)
  assert.equal(parseQuantity("100001"), null)
})

test("importes en pesos a centavos enteros", () => {
  assert.equal(parsePesos("1.500"), 150000)
  assert.equal(parsePesos("1500,50"), 150050)
  assert.equal(parsePesos("0"), 0)
  assert.equal(parsePesos("abc"), null)
})

test("subtotales, envío y total exactos", () => {
  const result = computeRetail({
    rows: [{ quantity: "2", price: "1.500", hasProduct: true }, { quantity: "3", price: "100,50", hasProduct: true }],
    shipping: "500"
  })
  assert.deepEqual(result.errors, [])
  assert.equal(result.lines[0].subtotal, 300000)
  assert.equal(result.lines[1].subtotal, 30150)
  assert.equal(result.subtotal, 330150)
  assert.equal(result.total, 380150)
})

test("el envío puede ser 0 y vacío cuenta como 0", () => {
  const result = computeRetail({ rows: [{ quantity: "1", price: "100", hasProduct: true }], shipping: "0" })
  assert.equal(result.total, 10000)
  assert.equal(computeRetail({ rows: [{ quantity: "1", price: "100", hasProduct: true }], shipping: "" }).total, 10000)
})

test("precio 0 es válido pero vacío no; filas vacías se ignoran; sin ítems es error", () => {
  assert.deepEqual(computeRetail({ rows: [{ quantity: "1", price: "0", hasProduct: true }] }).errors, [])
  assert.equal(computeRetail({ rows: [{ quantity: "1", price: "", hasProduct: true }] }).errors.length, 1)
  assert.deepEqual(computeRetail({ rows: [{ quantity: "", price: "", hasProduct: false }, { quantity: "1", price: "5", hasProduct: true }] }).errors, [])
  assert.deepEqual(computeRetail({ rows: [{ quantity: "", price: "", hasProduct: false }] }).errors, ["El pedido debe tener al menos un producto."])
})
