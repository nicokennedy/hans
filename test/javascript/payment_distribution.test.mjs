import test from "node:test"
import assert from "node:assert/strict"
import { formatPesos, parsePesos, suggest, summarize } from "../../app/javascript/payment_distribution.js"

const pesos = (n) => n * 100

test("parsePesos: pesos con o sin separadores, siempre en centavos enteros", () => {
  assert.equal(parsePesos("300000"), 30_000_000)
  assert.equal(parsePesos("300.000"), 30_000_000)
  assert.equal(parsePesos("$ 300.000"), 30_000_000)
  assert.equal(parsePesos("1.500,50"), 150_050)
  assert.equal(parsePesos("1500.5"), 150_050)
})

test("parsePesos rechaza lo ambiguo o inválido", () => {
  ;["", "  ", "abc", "12a", "1.2.3", "-100", "1e5", "300.00.0"].forEach((text) => assert.equal(parsePesos(text), null, text))
  assert.equal(parsePesos(null), null)
})

test("formatPesos es el inverso de parsePesos", () => {
  assert.equal(formatPesos(30_000_000), "300.000")
  assert.equal(formatPesos(150_050), "1.500,50")
  assert.equal(formatPesos(0), "0")
  ;[1, 100, 150_050, 30_000_000, 123_456_789].forEach((cents) => assert.equal(parsePesos(formatPesos(cents)), cents))
})

const honey = [
  { id: "1", balance: pesos(120_000) },
  { id: "2", balance: pesos(95_000) },
  { id: "3", balance: pesos(180_000) }
]

test("suggest: ejemplo del enunciado ($300.000 -> 120.000 / 95.000 / 85.000)", () => {
  const { allocations, unapplied } = suggest(honey, pesos(300_000))
  assert.deepEqual(allocations, { 1: pesos(120_000), 2: pesos(95_000), 3: pesos(85_000) })
  assert.equal(unapplied, 0)
})

test("suggest: nunca supera el saldo de un pedido y el sobrante queda sin aplicar", () => {
  const { allocations, unapplied } = suggest(honey, pesos(500_000))
  assert.deepEqual(allocations, { 1: pesos(120_000), 2: pesos(95_000), 3: pesos(180_000) })
  assert.equal(unapplied, pesos(105_000))
})

test("suggest: importes cero, negativos o inválidos no reparten nada; saldos cero se saltean", () => {
  assert.deepEqual(suggest(honey, 0).allocations, {})
  assert.deepEqual(suggest(honey, -50).allocations, {})
  assert.deepEqual(suggest(honey, NaN).allocations, {})
  assert.deepEqual(suggest([{ id: "9", balance: 0 }, { id: "8", balance: 500 }], 300).allocations, { 8: 300 })
})

test("summarize: monto recibido − distribuido = saldo sin aplicar, y saldo pendiente posterior", () => {
  const rows = [{ id: "1", balance: pesos(120_000), cents: pesos(120_000) }, { id: "2", balance: pesos(95_000), cents: pesos(95_000) }, { id: "3", balance: pesos(180_000), cents: pesos(85_000) }]
  const s = summarize({ amountCents: pesos(300_000), rows, pendingTotal: pesos(395_000) })

  assert.equal(s.received, pesos(300_000))
  assert.equal(s.applied, pesos(300_000))
  assert.equal(s.unapplied, 0)
  assert.equal(s.credit, 0)
  assert.equal(s.pendingAfter, pesos(95_000))
  assert.ok(s.valid)
})

test("summarize: excedente = saldo a favor generado", () => {
  const s = summarize({ amountCents: pesos(300_000), rows: [{ id: "1", balance: pesos(250_000), cents: pesos(250_000) }], pendingTotal: pesos(250_000) })
  assert.equal(s.credit, pesos(50_000))
  assert.equal(s.pendingAfter, 0)
  assert.ok(s.valid)
})

test("summarize: errores — supera el saldo, supera lo recibido, negativos e inválidos", () => {
  const over = summarize({ amountCents: pesos(100), rows: [{ id: "1", balance: pesos(50), cents: pesos(60) }], pendingTotal: pesos(50) })
  assert.ok(!over.valid)
  assert.ok(over.errors.some((e) => /no puede superar su saldo/.test(e)))

  const tooMuch = summarize({ amountCents: pesos(100), rows: [{ id: "1", balance: pesos(500), cents: pesos(60) }, { id: "2", balance: pesos(500), cents: pesos(60) }], pendingTotal: pesos(1000) })
  assert.ok(tooMuch.errors.some((e) => /supera el monto recibido/.test(e)))
  assert.ok(tooMuch.unapplied < 0)

  assert.ok(!summarize({ amountCents: 100, rows: [{ id: "1", balance: 100, cents: -5 }], pendingTotal: 100 }).valid)
  assert.ok(!summarize({ amountCents: 100, rows: [{ id: "1", balance: 100, cents: null, invalid: true }], pendingTotal: 100 }).valid)
})
