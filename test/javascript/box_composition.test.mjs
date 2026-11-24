import test from "node:test"
import assert from "node:assert/strict"
import { total, remaining, isComplete, canIncrement, canDecrement, increment, decrement, fill, summary } from "../../app/javascript/box_composition.js"

test("suma y faltantes; ignora negativos, decimales y texto", () => {
  assert.equal(total({ 1: 10, 2: 4 }), 14)
  assert.equal(total({ 1: -3, 2: "x", 3: 1.5, 4: 2 }), 2)
  assert.equal(remaining({ 1: 10 }, 24), 14)
  assert.equal(remaining({ 1: 30 }, 24), 0)
})

test("no supera la capacidad ni baja de cero", () => {
  let q = {}
  for (let i = 0; i < 30; i++) q = increment(q, "1", 8)
  assert.deepEqual(q, { 1: 8 })
  assert.equal(canIncrement(q, 8), false)
  q = decrement(decrement(q, "1", 20), "1")
  assert.deepEqual(q, {})
  assert.equal(canDecrement(q, "1"), false)
  assert.deepEqual(decrement({}, "9"), {})
})

test("solo está completa con la suma exacta", () => {
  assert.equal(isComplete({ 1: 12, 2: 11 }, 24), false)
  assert.equal(isComplete({ 1: 12, 2: 12 }, 24), true)
  assert.equal(isComplete({}, 0), false)
})

test("completar con un sabor: toda la caja de un mismo sabor en un toque", () => {
  assert.deepEqual(fill({}, "1", 24), { 1: 24 })
  assert.deepEqual(fill({ 2: 6 }, "1", 24), { 1: 18, 2: 6 })
  assert.deepEqual(fill({ 1: 24 }, "2", 24), { 1: 24 })
})

test("texto del contador", () => {
  assert.equal(summary({ 1: 12 }, 24), "12 de 24 · faltan 12")
  assert.equal(summary({ 1: 23 }, 24), "23 de 24 · falta 1")
  assert.equal(summary({ 1: 24 }, 24), "24 de 24 · caja completa")
})

test("no modifica el objeto original", () => {
  const original = { 1: 2 }
  increment(original, "1", 8)
  decrement(original, "1")
  fill(original, "2", 8)
  assert.deepEqual(original, { 1: 2 })
})
