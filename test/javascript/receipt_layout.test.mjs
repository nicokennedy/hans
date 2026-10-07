import test from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs"
import { CSS_PX_PER_MM, PDF_RECEIPT_WIDTH_PX, PRINT_DEFAULTS, captureWidthPx, layoutReceipts } from "../../app/javascript/receipt_layout.js"
import { buildPdf } from "../../app/javascript/pdf_writer.js"

const { pageWidth, pageHeight, margin, columns, columnGap, rowGap, receiptWidth } = PRINT_DEFAULTS
const usableWidth = pageWidth - 2 * margin // 281mm
const usableHeight = pageHeight - 2 * margin // 194mm
const EPS = 1e-6

// Remito capturado a su ancho natural (receiptWidth mm); `heightMm` es su alto real.
const receipt = (name, heightMm) => ({ name, width: receiptWidth * CSS_PX_PER_MM, height: heightMm * CSS_PX_PER_MM })

const placements = (layout) => layout.pages.flat()
const names = (page) => page.map((p) => `${p.item.name}#${p.copy}`)

function assertInsidePageAndNoOverlap(layout) {
  layout.pages.forEach((page, pageIndex) => {
    assert.ok(page.length > 0, `la página ${pageIndex + 1} está vacía`)

    page.forEach((p, i) => {
      assert.ok(p.x >= margin - EPS, "se sale por la izquierda")
      assert.ok(p.x + p.width <= pageWidth - margin + EPS, "se sale por la derecha")
      assert.ok(p.y >= margin - EPS, "se sale por arriba")
      assert.ok(p.y + p.height <= pageHeight - margin + EPS, "se sale por abajo (remito cortado)")

      page.slice(i + 1).forEach((q) => {
        const overlapX = p.x < q.x + q.width - EPS && q.x < p.x + p.width - EPS
        const overlapY = p.y < q.y + q.height - EPS && q.y < p.y + p.height - EPS
        assert.ok(!(overlapX && overlapY), "dos remitos se superponen")
      })
    })
  })
}

// --- Formato: A4 horizontal, 2 columnas, 135 mm -----------------------------

test("la hoja es A4 horizontal (297 x 210 mm), más ancha que alta", () => {
  assert.equal(pageWidth, 297)
  assert.equal(pageHeight, 210)
  assert.ok(pageWidth > pageHeight)
})

test("dos columnas de remitos de 135 mm con separación chica, dentro del ancho útil", () => {
  assert.equal(columns, 2)
  assert.equal(receiptWidth, 135)
  assert.ok(columnGap >= 3 && columnGap <= 5, "3-5 mm entre columnas")
  assert.ok(rowGap >= 3 && rowGap <= 5, "3-5 mm entre filas")
  assert.ok(columns * receiptWidth + (columns - 1) * columnGap <= usableWidth, "135 + separación + 135 entra en el ancho útil")
})

test("el ancho del remito es una constante: la captura (px) se deriva de ella, sin números sueltos", () => {
  assert.equal(PDF_RECEIPT_WIDTH_PX, captureWidthPx(receiptWidth))
  assert.equal(PDF_RECEIPT_WIDTH_PX, receiptWidth * CSS_PX_PER_MM) // 540px a 4px/mm
  assert.equal(captureWidthPx(130), 520)
  assert.equal(captureWidthPx(138), 552)
})

test("las dos copias de un pedido quedan lado a lado en la misma fila y a ancho completo (135 mm)", () => {
  const layout = layoutReceipts([receipt("A", 60)])
  const [first, second] = layout.pages[0]

  assert.equal(layout.pages[0].length, 2)
  assert.deepEqual(names(layout.pages[0]), ["A#0", "A#1"])
  assert.ok(Math.abs(first.y - second.y) < EPS, "misma fila")
  assert.ok(second.x > first.x, "la copia 2 está a la derecha de la copia 1")
  assert.ok(Math.abs(second.x - (first.x + first.width + columnGap)) < EPS, "separadas por columnGap")
  assert.ok(Math.abs(first.width - 135) < EPS && Math.abs(second.width - 135) < EPS)
  assert.equal(first.item, second.item, "son el mismo remito: dos copias idénticas")
  assert.equal(first.scaled, false)
  assertInsidePageAndNoOverlap(layout)
})

test("el par queda centrado horizontalmente en la hoja", () => {
  const [first, second] = layoutReceipts([receipt("A", 60)]).pages[0]
  const left = first.x - margin
  const right = pageWidth - margin - (second.x + second.width)
  assert.ok(Math.abs(left - right) < EPS)
})

// --- Altura dinámica y filas ------------------------------------------------

test("la altura de cada remito es la real: proporcional a su contenido, sin altura fija", () => {
  const layout = layoutReceipts([receipt("chico", 40), receipt("mediano", 70), receipt("grande", 120)])
  const heights = layout.pages.flat().filter((p) => p.copy === 0).map((p) => p.height)

  assert.deepEqual(heights.map((h) => Math.round(h)), [40, 70, 120])
  // y a 135mm de ancho: la proporción original se conserva
  layout.pages.flat().forEach((p) => assert.ok(Math.abs(p.height / p.width - p.item.height / p.item.width) < 1e-9))
})

test("las filas se apilan con el espacio configurado y empiezan en el margen superior", () => {
  const layout = layoutReceipts([receipt("A", 50), receipt("B", 50)])
  const rows = layout.pages[0].filter((p) => p.copy === 0)

  assert.equal(layout.pages.length, 1)
  assert.ok(Math.abs(rows[0].y - margin) < EPS)
  assert.ok(Math.abs(rows[1].y - (margin + 50 + rowGap)) < EPS)
  assertInsidePageAndNoOverlap(layout)
})

test("remitos bajos: entran más filas por hoja que con remitos altos", () => {
  const small = layoutReceipts(Array.from({ length: 4 }, (_, i) => receipt(`S${i}`, 40))) // 4 x 40 + 3 x 4 = 172 <= 194
  const big = layoutReceipts(Array.from({ length: 4 }, (_, i) => receipt(`B${i}`, 90)))

  assert.equal(small.pages.length, 1)
  assert.equal(small.pages[0].length, 8)
  assert.equal(big.pages.length, 2)
  assert.equal(big.pages[0].length, 4) // 90 + 4 + 90 = 184 <= 194; la tercera fila ya no entra
})

// --- Salto de página por pares, sin cortar ----------------------------------

test("si el siguiente par no entra completo, AMBAS copias pasan juntas a la hoja siguiente", () => {
  // 90 + 4 + 90 = 184 entra; una tercera fila de 90 haría 278 > 194
  const layout = layoutReceipts([receipt("A", 90), receipt("B", 90), receipt("C", 90)])

  assert.equal(layout.pages.length, 2)
  assert.deepEqual(names(layout.pages[0]), ["A#0", "A#1", "B#0", "B#1"])
  assert.deepEqual(names(layout.pages[1]), ["C#0", "C#1"], "las dos copias de C van juntas, ninguna queda en la hoja 1")
  assert.ok(Math.abs(layout.pages[1][0].y - margin) < EPS, "la fila que salta arranca arriba de la hoja nueva")
  assertInsidePageAndNoOverlap(layout)
})

test("el límite es exacto: una fila que entra justo se queda; un décimo de mm más y salta", () => {
  const first = 100
  const second = usableHeight - first - rowGap // llena la hoja exactamente

  const fits = layoutReceipts([receipt("A", first), receipt("B", second)])
  assert.equal(fits.pages.length, 1)
  assertInsidePageAndNoOverlap(fits)

  const over = layoutReceipts([receipt("A", first), receipt("B", second + 0.1)])
  assert.equal(over.pages.length, 2)
})

test("respeta el orden: no reordena pedidos para rellenar huecos", () => {
  const layout = layoutReceipts([receipt("A", 150), receipt("B", 100), receipt("C", 20)])

  assert.deepEqual(layout.pages.map((page) => [...new Set(page.map((p) => p.item.name))]), [["A"], ["B", "C"]])
})

test("nunca se genera una página vacía; sin remitos no hay páginas", () => {
  assert.deepEqual(layoutReceipts([]).pages, [])
  const layout = layoutReceipts([receipt("A", 190), receipt("B", 190)])
  layout.pages.forEach((page) => assert.ok(page.length > 0))
})

// --- Pedidos largos y reducción de escala ------------------------------------

test("un pedido largo que entra en la hoja NO se escala (15-20 productos)", () => {
  const layout = layoutReceipts([receipt("LARGO", 143)]) // 18 productos con comentario ≈ 143mm
  layout.pages[0].forEach((p) => {
    assert.equal(p.scaled, false)
    assert.ok(Math.abs(p.width - receiptWidth) < EPS)
  })
})

test("solo si un remito es más alto que la hoja se reduce, lo mínimo necesario, y queda completo", () => {
  const huge = receipt("HUGE", usableHeight * 1.25) // 242mm de alto a 135 de ancho
  const layout = layoutReceipts([huge, receipt("B", 50)])
  const [first, second] = layout.pages[0]

  assert.equal(first.scaled, true)
  assert.ok(Math.abs(first.height - usableHeight) < EPS, "ocupa exactamente el alto útil")
  assert.ok(first.width < receiptWidth)
  assert.ok(Math.abs(first.width / first.height - huge.width / huge.height) < 1e-9, "mantiene la proporción")
  assert.ok(Math.abs(first.width - second.width) < EPS, "las dos copias se reducen igual")
  assert.equal(layout.pages.length, 2, "ocupa la hoja entera: el siguiente pedido va a la próxima")
  assertInsidePageAndNoOverlap(layout)
})

test("un remito alto sin escalar no afecta la escala de los demás", () => {
  const layout = layoutReceipts([receipt("HUGE", 300), receipt("B", 50)])
  const b = layout.pages[1][0]
  assert.equal(b.scaled, false)
  assert.ok(Math.abs(b.width - receiptWidth) < EPS)
})

// --- Configuración: otros anchos, copias, columnas ---------------------------

test("el ancho objetivo se puede cambiar por opción (130 / 138 mm) sin tocar el algoritmo", () => {
  ;[130, 135, 138].forEach((w) => {
    const item = { name: "A", width: captureWidthPx(w), height: 60 * CSS_PX_PER_MM }
    const [first, second] = layoutReceipts([item], { receiptWidth: w }).pages[0]

    assert.ok(Math.abs(first.width - w) < EPS)
    assert.ok(Math.abs(first.height - 60) < EPS)
    assert.ok(second.x + second.width <= pageWidth - margin + EPS)
  })
})

test("si el ancho pedido no entra en dos columnas se reduce para que entren (no se sale de la hoja)", () => {
  const layout = layoutReceipts([receipt("A", 60)], { receiptWidth: 160 })
  const [first, second] = layout.pages[0]

  assert.equal(first.scaled, true)
  assert.ok(first.width < 160)
  assert.ok(second.x + second.width <= pageWidth - margin + EPS)
  assertInsidePageAndNoOverlap(layout)
})

test("con más copias que columnas siguen en otra fila, siempre juntas en la misma página", () => {
  const layout = layoutReceipts([receipt("A", 40), receipt("B", 40)], { copies: 3 }) // cada pedido: 2 filas = 84mm

  assert.equal(layout.pages.length, 1)
  assert.deepEqual(names(layout.pages[0]), ["A#0", "A#1", "A#2", "B#0", "B#1", "B#2"])
  const a = layout.pages[0]
  assert.ok(a[2].y > a[0].y, "la 3ª copia baja a la fila siguiente")
  assertInsidePageAndNoOverlap(layout)
})

test("con 1 copia solo se coloca esa copia", () => {
  assert.equal(layoutReceipts([receipt("A", 60)], { copies: 1 }).pages[0].length, 1)
})

test("datos inválidos: copias, tamaños no positivos o márgenes que no dejan lugar", () => {
  assert.throws(() => layoutReceipts([receipt("A", 60)], { copies: 0 }), RangeError)
  assert.throws(() => layoutReceipts([receipt("A", 60)], { copies: 1.5 }), RangeError)
  assert.throws(() => layoutReceipts([receipt("A", 60)], { columns: 0 }), RangeError)
  assert.throws(() => layoutReceipts([{ width: 0, height: 10 }]), RangeError)
  assert.throws(() => layoutReceipts([{ width: 10, height: -1 }]), RangeError)
  assert.throws(() => layoutReceipts([receipt("A", 10)], { margin: 150 }), RangeError)
})

// --- Propiedades generales ----------------------------------------------------

test("propiedad: con muchos pedidos de alturas variadas nunca se corta, superpone ni deja hojas vacías", () => {
  let seed = 42
  const random = () => { seed = (seed * 1664525 + 1013904223) % 4294967296; return seed / 4294967296 }

  for (let run = 0; run < 60; run++) {
    const count = 1 + Math.floor(random() * 40)
    // Alturas entre 30mm (1-2 productos) y 250mm (más alto que una hoja)
    const items = Array.from({ length: count }, (_, i) => receipt(`R${i}`, 30 + random() * 220))
    const layout = layoutReceipts(items)

    assert.equal(placements(layout).length, count * 2, "se colocan las 2 copias de cada pedido")
    assertInsidePageAndNoOverlap(layout)

    layout.pages.forEach((page) => {
      const byOrder = Object.groupBy(page, (p) => p.item.name)
      Object.values(byOrder).forEach((copies) => {
        assert.equal(copies.length, 2, "las 2 copias de un pedido están en la misma hoja")
        assert.ok(Math.abs(copies[0].y - copies[1].y) < EPS, "...y en la misma fila")
      })
    })

    const order = [...new Set(placements(layout).map((p) => p.item.name))]
    assert.deepEqual(order, items.map((r) => r.name), "orden preservado")
  }
})

test("12 pedidos de tamaños distintos se distribuyen en las hojas necesarias, bien aprovechadas", () => {
  const heights = [45, 60, 80, 100, 55, 70, 90, 50, 110, 65, 75, 85]
  const layout = layoutReceipts(heights.map((h, i) => receipt(`P${i + 1}`, h)))

  assert.equal(placements(layout).length, 24)
  assertInsidePageAndNoOverlap(layout)
  assert.ok(layout.pages.length >= Math.ceil(heights.reduce((s, h) => s + h + rowGap, 0) / usableHeight))
  assert.ok(layout.pages.length <= 6, "mucho menos que una hoja por remito")
})

// --- Legibilidad: el CSS de impresión debe dar letra física de 9-10pt ---------

test("el cuerpo del remito compacto sale a 9-10 pt reales (13.5px a 4px/mm)", () => {
  const scss = fs.readFileSync(new URL("../../app/assets/stylesheets/application.scss", import.meta.url), "utf8")
  const block = scss.slice(scss.indexOf("receipt-print-compact.hans-receipt"))
  const px = Number(block.match(/font-size:\s*([\d.]+)px/)[1])
  const pt = (px / CSS_PX_PER_MM) * (72 / 25.4)

  assert.ok(pt >= 9 && pt <= 10, `el cuerpo mide ${pt.toFixed(2)}pt`)
})

// --- PDF: orientación horizontal ----------------------------------------------

test("el PDF generado tiene páginas A4 horizontales y es válido con las posiciones del layout", () => {
  const fakeJpeg = (n) => new Uint8Array([0xff, 0xd8, ...new Array(n).fill(0x41), 0xff, 0xd9])
  const items = [receipt("A", 60), receipt("B", 150), receipt("C", 150)]
  const layout = layoutReceipts(items)
  const images = items.map((item) => ({ data: fakeJpeg(50), width: item.width * 3, height: item.height * 3 }))

  const bytes = buildPdf({
    pageWidth,
    pageHeight,
    images,
    pages: layout.pages.map((page) => page.map(({ item, x, y, width, height }) => ({ imageIndex: items.indexOf(item), x, y, width, height })))
  })
  const pdf = Buffer.from(bytes).toString("latin1")

  assert.ok(pdf.startsWith("%PDF-1.4"))
  assert.ok(pdf.trimEnd().endsWith("%%EOF"))
  const boxes = [...pdf.matchAll(/\/MediaBox \[0 0 ([\d.]+) ([\d.]+)\]/g)].map((m) => [Number(m[1]), Number(m[2])])
  assert.equal(boxes.length, layout.pages.length)
  boxes.forEach(([w, h]) => {
    assert.ok(Math.abs(w - 841.89) < 0.1 && Math.abs(h - 595.28) < 0.1, `página ${w}x${h}pt (esperado 842x595, horizontal)`)
    assert.ok(w > h)
  })
  assert.equal(Number(pdf.match(/\/Count (\d+)/)[1]), layout.pages.length)
})
