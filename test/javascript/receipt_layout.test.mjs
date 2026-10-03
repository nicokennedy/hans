import test from "node:test"
import assert from "node:assert/strict"
import { PRINT_DEFAULTS, expandCopies, layoutReceipts } from "../../app/javascript/receipt_layout.js"

const { pageWidth, pageHeight, margin, gap } = PRINT_DEFAULTS
const usableWidth = pageWidth - 2 * margin // 194mm
const usableHeight = pageHeight - 2 * margin // 281mm
const EPS = 1e-6

// Remito de proporción conocida: a todo el ancho útil mide `mm` de alto.
const receipt = (name, heightMm) => ({ name, width: usableWidth, height: heightMm })

const flat = (layout) => layout.pages.flat()

function assertNoOverlapAndInsidePage(layout) {
  layout.pages.forEach((page, pageIndex) => {
    assert.ok(page.length > 0, `la página ${pageIndex + 1} está vacía`)

    page.forEach((p, i) => {
      assert.ok(p.x >= margin - EPS, "se sale por la izquierda")
      assert.ok(p.x + p.width <= pageWidth - margin + EPS, "se sale por la derecha")
      assert.ok(p.y >= margin - EPS, "se sale por arriba")
      assert.ok(p.y + p.height <= pageHeight - margin + EPS, "se sale por abajo (remito cortado)")

      if (i > 0) {
        const previous = page[i - 1]
        assert.ok(p.y >= previous.y + previous.height - EPS, "se superpone con el remito anterior")
      }
    })
  })
}

test("expandCopies genera exactamente 2 copias consecutivas de cada remito", () => {
  const a = receipt("A", 60)
  const b = receipt("B", 90)

  const expanded = expandCopies([a, b])

  assert.deepEqual(expanded.map((r) => r.name), ["A", "A", "B", "B"])
  assert.equal(expanded[0], expanded[1])
})

test("expandCopies valida la cantidad de copias", () => {
  assert.throws(() => expandCopies([receipt("A", 60)], 0), RangeError)
  assert.throws(() => expandCopies([receipt("A", 60)], 1.5), RangeError)
  assert.equal(expandCopies([receipt("A", 60)], 3).length, 3)
})

test("sin remitos no se genera ninguna página (nunca hay páginas vacías)", () => {
  assert.deepEqual(layoutReceipts([]).pages, [])
})

test("varios remitos chicos entran en una sola hoja, apilados con el espacio configurado", () => {
  const layout = layoutReceipts(expandCopies([receipt("A", 50), receipt("B", 50)]))

  assert.equal(layout.pages.length, 1)
  const placements = layout.pages[0]
  assert.deepEqual(placements.map((p) => p.item.name), ["A", "A", "B", "B"])
  assert.ok(Math.abs(placements[0].y - margin) < EPS)
  assert.ok(Math.abs(placements[1].y - (margin + 50 + gap)) < EPS)
  assertNoOverlapAndInsidePage(layout)
})

test("usa la altura real de cada remito: uno chico deja lugar para más que uno grande", () => {
  const small = layoutReceipts(expandCopies([receipt("S1", 40), receipt("S2", 40), receipt("S3", 40)]))
  const big = layoutReceipts(expandCopies([receipt("B1", 120), receipt("B2", 120), receipt("B3", 120)]))

  assert.equal(small.pages.length, 1) // 6 x 40mm + gaps entran en una hoja
  assert.ok(big.pages.length > 1)
  assert.equal(big.pages[0].length, 2) // 120 + 4 + 120 = 244 <= 281; un tercero ya no entra
})

test("si el siguiente remito no entra completo pasa ENTERO a la página siguiente", () => {
  // 100 + 4 + 100 = 204 entra; el tercero (100) haría 308 > 281 -> página 2
  const layout = layoutReceipts([receipt("A", 100), receipt("B", 100), receipt("C", 100)])

  assert.equal(layout.pages.length, 2)
  assert.deepEqual(layout.pages[0].map((p) => p.item.name), ["A", "B"])
  assert.deepEqual(layout.pages[1].map((p) => p.item.name), ["C"])
  assert.ok(Math.abs(layout.pages[1][0].y - margin) < EPS, "el remito que salta arriba de la nueva hoja")
  assertNoOverlapAndInsidePage(layout)
})

test("el límite es exacto: un remito que entra justo se queda en la hoja", () => {
  const first = 100
  const second = usableHeight - first - gap // llena la hoja exactamente
  const layout = layoutReceipts([receipt("A", first), receipt("B", second)])

  assert.equal(layout.pages.length, 1)
  assertNoOverlapAndInsidePage(layout)

  const justOver = layoutReceipts([receipt("A", first), receipt("B", second + 0.01)])
  assert.equal(justOver.pages.length, 2)
})

test("respeta el orden: no reordena remitos para rellenar huecos", () => {
  const layout = layoutReceipts([receipt("A", 200), receipt("B", 150), receipt("C", 20)])

  assert.deepEqual(flat(layout).map((p) => p.item.name), ["A", "B", "C"])
  assert.deepEqual(layout.pages.map((page) => page.map((p) => p.item.name)), [["A"], ["B", "C"]])
})

test("un remito más alto que una hoja se reduce proporcionalmente y queda completo y centrado", () => {
  const huge = { name: "HUGE", width: usableWidth, height: usableHeight * 1.5 } // 421mm a todo el ancho
  const layout = layoutReceipts([huge, receipt("B", 50)])

  const placement = layout.pages[0][0]
  assert.equal(placement.scaled, true)
  assert.ok(Math.abs(placement.height - usableHeight) < EPS)
  assert.ok(Math.abs(placement.width / placement.height - huge.width / huge.height) < 1e-9, "mantiene la proporción")
  assert.ok(Math.abs(placement.x - (pageWidth - placement.width) / 2) < EPS, "queda centrado")
  assert.equal(layout.pages.length, 2) // ocupa la hoja entera, el siguiente va a la próxima
  assertNoOverlapAndInsidePage(layout)
})

test("los remitos normales no se reducen", () => {
  const layout = layoutReceipts([receipt("A", 100)])
  assert.equal(layout.pages[0][0].scaled, false)
  assert.ok(Math.abs(layout.pages[0][0].width - usableWidth) < EPS)
})

test("datos inválidos: tamaños no positivos o márgenes que no dejan lugar", () => {
  assert.throws(() => layoutReceipts([{ width: 0, height: 10 }]), RangeError)
  assert.throws(() => layoutReceipts([{ width: 10, height: -1 }]), RangeError)
  assert.throws(() => layoutReceipts([receipt("A", 10)], { margin: 150 }), RangeError)
})

test("propiedad: con muchos remitos de alturas variadas nunca se corta, superpone ni deja páginas vacías", () => {
  let seed = 42
  const random = () => { seed = (seed * 1664525 + 1013904223) % 4294967296; return seed / 4294967296 }

  for (let run = 0; run < 50; run++) {
    const count = 1 + Math.floor(random() * 40)
    // Alturas entre 30mm (pedido de 1-2 items) y 330mm (más alto que una hoja)
    const items = Array.from({ length: count }, (_, i) => receipt(`R${i}`, 30 + random() * 300))
    const layout = layoutReceipts(expandCopies(items))

    assert.equal(flat(layout).length, count * 2, "se colocan las 2 copias de cada remito")
    assertNoOverlapAndInsidePage(layout)
    assert.deepEqual(flat(layout).map((p) => p.item.name), expandCopies(items).map((r) => r.name), "orden preservado")
  }
})

test("12 pedidos = 24 remitos, distribuidos automáticamente en las hojas necesarias", () => {
  const heights = [45, 60, 80, 100, 55, 70, 90, 50, 110, 65, 75, 85] // 12 pedidos de distinto tamaño
  const layout = layoutReceipts(expandCopies(heights.map((h, i) => receipt(`P${i + 1}`, h))))

  assert.equal(flat(layout).length, 24)
  assertNoOverlapAndInsidePage(layout)

  // Aprovechamiento: nunca más hojas que las del apilado sin optimizar (una por remito)
  assert.ok(layout.pages.length < 24)
  // Cota inferior: el total de altura real dividido por la altura útil
  const totalHeight = heights.reduce((sum, h) => sum + 2 * h, 0)
  assert.ok(layout.pages.length >= Math.ceil(totalHeight / usableHeight))
})
