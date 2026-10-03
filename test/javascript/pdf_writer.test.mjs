import test from "node:test"
import assert from "node:assert/strict"
import { buildPdf } from "../../app/javascript/pdf_writer.js"

// JPEG "de mentira": para el escritor solo importan los bytes y las dimensiones.
const fakeJpeg = (size, fill) => new Uint8Array([0xff, 0xd8, ...new Array(size).fill(fill), 0xff, 0xd9])

const text = (bytes) => Buffer.from(bytes).toString("latin1")

function buildSample() {
  const images = [
    { data: fakeJpeg(300, 0x41), width: 2280, height: 1500 },
    { data: fakeJpeg(200, 0x42), width: 2280, height: 900 }
  ]
  const pages = [
    [
      { imageIndex: 0, x: 8, y: 8, width: 194, height: 127.6 },
      { imageIndex: 0, x: 8, y: 139.6, width: 194, height: 127.6 } // 2da copia: misma imagen
    ],
    [{ imageIndex: 1, x: 8, y: 8, width: 194, height: 76.6 }]
  ]
  return { images, pages, bytes: buildPdf({ images, pages, title: "Remitos (prueba)" }) }
}

test("el PDF tiene cabecera, fin de archivo y tabla xref con offsets correctos", () => {
  const { bytes } = buildSample()
  const pdf = text(bytes)

  assert.ok(pdf.startsWith("%PDF-1.4"))
  assert.ok(pdf.trimEnd().endsWith("%%EOF"))

  const startxref = Number(pdf.match(/startxref\n(\d+)\n%%EOF/)[1])
  assert.ok(pdf.slice(startxref).startsWith("xref\n"))

  const size = Number(pdf.match(/trailer\n<< \/Size (\d+)/)[1])
  const entries = pdf.slice(startxref).split("\n").slice(2, 2 + size) // salta "xref" y "0 N"
  assert.equal(entries.length, size)
  assert.equal(entries[0], "0000000000 65535 f ")

  entries.slice(1).forEach((entry, i) => {
    const id = i + 1
    assert.equal(entry.length, 19) // 10 + " 00000 n " (el \n completa los 20 bytes)
    const offset = Number(entry.slice(0, 10))
    assert.ok(pdf.slice(offset).startsWith(`${id} 0 obj\n`), `el offset del objeto ${id} no apunta a "${id} 0 obj"`)
  })
})

test("las páginas son A4 vertical (595.276 x 841.890 pt) y se cuentan bien", () => {
  const { bytes } = buildSample()
  const pdf = text(bytes)

  assert.match(pdf, /\/Count 2/)
  assert.equal(pdf.match(/\/Type \/Page /g).length, 2)
  assert.equal(pdf.match(/\/MediaBox \[0 0 595\.276 841\.890\]/g).length, 2)
})

test("una imagen colocada dos veces (las 2 copias) se guarda una sola vez", () => {
  const { bytes, images } = buildSample()
  const pdf = text(bytes)

  assert.equal(pdf.match(/\/Subtype \/Image/g).length, images.length)
  assert.equal(pdf.match(/\/Im0 Do/g).length, 2) // dos posiciones, una imagen
  assert.equal(pdf.match(/\/Im1 Do/g).length, 1)
})

test("las imágenes JPEG se incluyen intactas con su /Length correcto", () => {
  const { bytes, images } = buildSample()
  const pdf = text(bytes)

  images.forEach((image) => {
    assert.ok(pdf.includes(`/Length ${image.data.length} >>\nstream\n${text(image.data)}\nendstream`))
  })
})

test("la posición se convierte de mm (origen arriba) a puntos PDF (origen abajo)", () => {
  const { bytes } = buildSample()
  const pdf = text(bytes)
  // Primer remito: 194 x 127.6 mm en x=8, y=8 -> y PDF = 297 - 8 - 127.6 = 161.4mm
  const mm = (v) => ((v * 72) / 25.4).toFixed(3)
  assert.ok(pdf.includes(`q ${mm(194)} 0 0 ${mm(127.6)} ${mm(8)} ${mm(161.4)} cm /Im0 Do Q`))
})

test("el título se escapa para no romper la sintaxis del PDF", () => {
  const { bytes } = buildSample()
  assert.ok(text(bytes).includes("/Title (Remitos \\(prueba\\))"))
})
