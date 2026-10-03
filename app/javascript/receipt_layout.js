// Armado de páginas A4 para la impresión masiva de remitos. Es lógica pura
// (sin DOM, sin canvas): recibe el tamaño real de cada remito ya capturado y
// devuelve en qué página y posición va cada uno, así se puede testear con
// `node --test` sin un navegador (ver test/javascript/).
//
// Reglas:
//  - Se acomodan en orden, de arriba hacia abajo, apilados a todo el ancho
//    útil de la hoja. Cada remito ocupa su altura REAL (proporcional a su
//    contenido), no un tamaño fijo: uno de 3 productos ocupa poco y entran
//    varios por hoja; uno de 20 ocupa casi toda la hoja.
//  - Un remito nunca se corta entre dos páginas: si no entra completo en el
//    espacio que queda, pasa entero a la página siguiente.
//  - Si un remito solo, a todo el ancho, es más alto que una hoja entera, se
//    reduce la escala (manteniendo la proporción) hasta que entre. Con los
//    pedidos actuales (máx. ~20 items) la reducción es leve.
//  - Nunca se genera una página vacía: una página existe solo si tiene algo.

export const PRINT_DEFAULTS = Object.freeze({
  pageWidth: 210, // mm, A4 vertical
  pageHeight: 297,
  margin: 8, // mm; seguro para impresoras comunes (zona no imprimible ~5mm)
  gap: 4, // mm entre remitos consecutivos
  copies: 2 // una queda en el comercio, otra vuelve firmada con el repartidor
})

// Ancho (px) con el que se captura cada remito para el PDF. Es el mismo
// diseño de escritorio del PNG (.receipt-export-render), solo más angosto
// que los 1100px del PNG. Al escalarlo al ancho útil de la hoja (194mm) el
// texto del cuerpo queda en ≈9,8pt y las etiquetas en ≈8pt: legible, y los
// remitos salen ~15% más bajos que a 760px, así entran más por hoja.
export const PDF_RECEIPT_WIDTH_PX = 900

const EPSILON = 1e-6

// Repite cada remito `copies` veces de forma consecutiva:
// [A, B] con 2 copias -> [A, A, B, B]
export function expandCopies(items, copies = PRINT_DEFAULTS.copies) {
  if (!Number.isInteger(copies) || copies < 1) {
    throw new RangeError("La cantidad de copias debe ser un entero >= 1")
  }

  return items.flatMap((item) => Array.from({ length: copies }, () => item))
}

// items: [{ width, height }] en cualquier unidad (solo importa la proporción).
// Devuelve { pages: [[{ item, x, y, width, height, scaled }]] } en mm, con el
// origen arriba a la izquierda de la hoja.
export function layoutReceipts(items, options = {}) {
  const { pageWidth, pageHeight, margin, gap } = { ...PRINT_DEFAULTS, ...options }

  const usableWidth = pageWidth - 2 * margin
  const usableHeight = pageHeight - 2 * margin
  const bottom = margin + usableHeight

  if (usableWidth <= 0 || usableHeight <= 0) {
    throw new RangeError("Los márgenes no dejan espacio útil en la hoja")
  }

  const pages = []
  let current = null
  let cursorY = 0

  items.forEach((item) => {
    if (!(item.width > 0) || !(item.height > 0)) {
      throw new RangeError("Cada remito necesita ancho y alto positivos")
    }

    let width = usableWidth
    let height = (item.height / item.width) * width
    let scaled = false

    if (height > usableHeight + EPSILON) {
      const factor = usableHeight / height
      width *= factor
      height = usableHeight
      scaled = true
    }

    const fitsInCurrentPage = current !== null && cursorY + gap + height <= bottom + EPSILON

    if (fitsInCurrentPage) {
      cursorY += gap
    } else {
      current = []
      pages.push(current)
      cursorY = margin
    }

    current.push({
      item,
      x: margin + (usableWidth - width) / 2,
      y: cursorY,
      width,
      height,
      scaled
    })

    cursorY += height
  })

  return { pages }
}
