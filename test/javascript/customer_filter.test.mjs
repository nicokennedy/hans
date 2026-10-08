import test from "node:test"
import assert from "node:assert/strict"
import { normalize, resolveCustomer } from "../../app/javascript/customer_filter.js"

const options = [
  { name: "Honey", id: "15" },
  { name: "Café Central", id: "7" },
  { name: "Panadería La Esquina", id: "9" }
]

test("normalize ignora mayúsculas, tildes y espacios de más", () => {
  assert.equal(normalize("  CAFÉ   central "), "cafe central")
  assert.equal(normalize(null), "")
})

test("texto vacío = todos los clientes (válido, sin id)", () => {
  assert.deepEqual(resolveCustomer(options, ""), { id: "", valid: true })
  assert.deepEqual(resolveCustomer(options, "   "), { id: "", valid: true })
})

test("un nombre exacto de la lista resuelve el id del cliente", () => {
  assert.deepEqual(resolveCustomer(options, "Honey"), { id: "15", valid: true })
  assert.deepEqual(resolveCustomer(options, "honey"), { id: "15", valid: true })
  assert.deepEqual(resolveCustomer(options, "cafe central"), { id: "7", valid: true })
  assert.deepEqual(resolveCustomer(options, "  Panadería  La Esquina "), { id: "9", valid: true })
})

test("un texto que no es un cliente de la lista es inválido y no manda ningún id", () => {
  assert.deepEqual(resolveCustomer(options, "Hon"), { id: "", valid: false })
  assert.deepEqual(resolveCustomer(options, "Otro"), { id: "", valid: false })
  assert.deepEqual(resolveCustomer([], "Honey"), { id: "", valid: false })
})
