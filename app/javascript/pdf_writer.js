// Escritor mínimo de PDF: páginas con imágenes JPEG posicionadas. No agrega
// ninguna dependencia — para este caso (imágenes de los remitos sobre hojas
// A4) alcanza con un PDF 1.4 con XObjects de imagen DCTDecode.
//
// Si una misma imagen se coloca más de una vez (las dos copias de un remito)
// se guarda UNA sola vez en el archivo y se referencia desde cada posición.
//
// Entrada (mm, origen arriba a la izquierda, como devuelve receipt_layout.js):
//   images: [{ data: Uint8Array (JPEG), width, height }]  (px del JPEG)
//   pages:  [[{ imageIndex, x, y, width, height }]]
// Salida: Uint8Array con el PDF completo.

const MM_TO_PT = 72 / 25.4

function pt(mm) {
  return (mm * MM_TO_PT).toFixed(3)
}

function escapePdfString(text) {
  return String(text).replace(/[^\x20-\x7e]/g, "?").replace(/([\\()])/g, "\\$1")
}

export function buildPdf({ pageWidth = 210, pageHeight = 297, images, pages, title = "Remitos" }) {
  const encoder = new TextEncoder()
  const chunks = []
  const offsets = []
  let length = 0

  const write = (chunk) => {
    const bytes = typeof chunk === "string" ? encoder.encode(chunk) : chunk
    chunks.push(bytes)
    length += bytes.length
  }

  const beginObject = (id) => {
    offsets[id] = length
    write(`${id} 0 obj\n`)
  }

  // Numeración fija: 1 catálogo, 2 árbol de páginas, 3 info, luego imágenes,
  // luego (página, contenido) por cada hoja.
  const imageObjectId = (index) => 4 + index
  const firstPageObjectId = 4 + images.length
  const pageObjectId = (pageIndex) => firstPageObjectId + pageIndex * 2
  const contentObjectId = (pageIndex) => pageObjectId(pageIndex) + 1
  const totalObjects = firstPageObjectId + pages.length * 2 - 1

  write("%PDF-1.4\n")
  write(new Uint8Array([0x25, 0xe2, 0xe3, 0xcf, 0xd3, 0x0a])) // marca de contenido binario

  beginObject(1)
  write("<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")

  beginObject(2)
  const kids = pages.map((_, i) => `${pageObjectId(i)} 0 R`).join(" ")
  write(`<< /Type /Pages /Kids [${kids}] /Count ${pages.length} >>\nendobj\n`)

  beginObject(3)
  write(`<< /Title (${escapePdfString(title)}) /Producer (HANS) >>\nendobj\n`)

  images.forEach((image, index) => {
    beginObject(imageObjectId(index))
    write(
      `<< /Type /XObject /Subtype /Image /Width ${image.width} /Height ${image.height} ` +
      `/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ${image.data.length} >>\nstream\n`
    )
    write(image.data)
    write("\nendstream\nendobj\n")
  })

  pages.forEach((placements, pageIndex) => {
    const usedImages = [...new Set(placements.map((p) => p.imageIndex))]
    const xobjects = usedImages.map((i) => `/Im${i} ${imageObjectId(i)} 0 R`).join(" ")

    beginObject(pageObjectId(pageIndex))
    write(
      `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${pt(pageWidth)} ${pt(pageHeight)}] ` +
      `/Resources << /XObject << ${xobjects} >> >> /Contents ${contentObjectId(pageIndex)} 0 R >>\nendobj\n`
    )

    // En PDF el origen está abajo a la izquierda: se invierte Y.
    const content = placements.map((p) => {
      const bottom = pageHeight - p.y - p.height
      return `q ${pt(p.width)} 0 0 ${pt(p.height)} ${pt(p.x)} ${pt(bottom)} cm /Im${p.imageIndex} Do Q\n`
    }).join("")

    beginObject(contentObjectId(pageIndex))
    write(`<< /Length ${content.length} >>\nstream\n${content}endstream\nendobj\n`)
  })

  const xrefOffset = length
  write(`xref\n0 ${totalObjects + 1}\n`)
  write("0000000000 65535 f \n")
  for (let id = 1; id <= totalObjects; id++) {
    write(`${String(offsets[id]).padStart(10, "0")} 00000 n \n`)
  }
  write(`trailer\n<< /Size ${totalObjects + 1} /Root 1 0 R /Info 3 0 R >>\nstartxref\n${xrefOffset}\n%%EOF\n`)

  const output = new Uint8Array(length)
  let position = 0
  chunks.forEach((chunk) => {
    output.set(chunk, position)
    position += chunk.length
  })
  return output
}
