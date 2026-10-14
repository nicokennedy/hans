import test from "node:test"
import assert from "node:assert/strict"
import { isAvailableTo, matchesName, normalize, selectionSummary } from "../../app/javascript/product_visibility.js"

test("productos para todos están disponibles para cualquier cliente, con o sin cliente elegido", () => {
  assert.equal(isAvailableTo({ visibility: "all", customerIds: [] }, "7"), true)
  assert.equal(isAvailableTo({ visibility: "all", customerIds: [] }, ""), true)
})

test("productos restringidos solo para sus clientes; sin cliente elegido no se ofrecen", () => {
  const option = { visibility: "selected", customerIds: ["1", "3"] }
  assert.equal(isAvailableTo(option, "1"), true)
  assert.equal(isAvailableTo(option, 3), true)
  assert.equal(isAvailableTo(option, "2"), false)
  assert.equal(isAvailableTo(option, ""), false)
  assert.equal(isAvailableTo(option, undefined), false)
})

test("el buscador ignora mayúsculas, tildes y espacios de más", () => {
  assert.equal(matchesName("Café Central", "cafe"), true)
  assert.equal(matchesName("Café Central", "  CENTRAL "), true)
  assert.equal(matchesName("Café Central", "norte"), false)
  assert.equal(matchesName("Café Central", ""), true)
  assert.equal(normalize("  Ñandú   Bar "), "nandu bar")
})

test("resumen de la selección", () => {
  assert.equal(selectionSummary(0), "Ningún cliente seleccionado")
  assert.equal(selectionSummary(1), "1 cliente seleccionado")
  assert.equal(selectionSummary(4), "4 clientes seleccionados")
})
