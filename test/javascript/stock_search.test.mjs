import test from "node:test"
import assert from "node:assert/strict"
import { matches, normalize } from "../../app/javascript/stock_search.js"

const NAMES = ["Base Cheesecake", "Cuadrado Brownie", "Mini Brownie", "Tapas Alfajor Almendra", "Tapas Alfajor Limón", "Base Alfajor Brownie", "Mini oreo capas", "Budín de limón"]
const search = (query) => NAMES.filter((name) => matches(name, query))

test("'brownie' muestra todos los nombres que lo contienen", () => {
  assert.deepEqual(search("brownie"), ["Cuadrado Brownie", "Mini Brownie", "Base Alfajor Brownie"])
})

test("'alfajor' muestra las bases/tapas con Alfajor en el nombre", () => {
  assert.deepEqual(search("alfajor"), ["Tapas Alfajor Almendra", "Tapas Alfajor Limón", "Base Alfajor Brownie"])
})

test("'cheese' encuentra Base Cheesecake", () => {
  assert.deepEqual(search("cheese"), ["Base Cheesecake"])
})

test("no distingue mayúsculas/minúsculas", () => {
  assert.deepEqual(search("BROWNIE"), search("brownie"))
  assert.deepEqual(search("bRoWnIe"), search("brownie"))
})

test("coincidencia parcial en cualquier parte del nombre", () => {
  assert.deepEqual(search("wni"), ["Cuadrado Brownie", "Mini Brownie", "Base Alfajor Brownie"])
  assert.deepEqual(search("capas"), ["Mini oreo capas"])
})

test("tolera tildes en ambos sentidos", () => {
  assert.deepEqual(search("limon"), ["Tapas Alfajor Limón", "Budín de limón"])
  assert.deepEqual(search("budin"), ["Budín de limón"])
  assert.deepEqual(search("limón"), ["Tapas Alfajor Limón", "Budín de limón"])
})

test("varias palabras: todas deben estar, en cualquier orden", () => {
  assert.deepEqual(search("mini brownie"), ["Mini Brownie"])
  assert.deepEqual(search("brownie mini"), ["Mini Brownie"])
  assert.deepEqual(search("alfajor brownie"), ["Base Alfajor Brownie"])
})

test("un texto vacío o solo espacios muestra todo", () => {
  assert.equal(search("").length, NAMES.length)
  assert.equal(search("   ").length, NAMES.length)
})

test("sin coincidencias devuelve vacío", () => {
  assert.deepEqual(search("zzzz"), [])
})

test("ignora espacios de más", () => {
  assert.deepEqual(search("  mini    oreo "), ["Mini oreo capas"])
  assert.equal(normalize("  Hola   Mundo "), "hola mundo")
})
