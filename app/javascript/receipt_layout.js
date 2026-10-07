// Armado de hojas para la impresión masiva de remitos. Es lógica pura (sin
// DOM, sin canvas): recibe el tamaño real de cada remito ya capturado y
// devuelve en qué página y posición va cada copia, así se puede testear con
// `node --test` sin un navegador (ver test/javascript/).
//
// Formato: A4 HORIZONTAL (297 x 210 mm) con 2 columnas. Las dos copias de un
// mismo pedido van LADO A LADO, en la misma fila, y son idénticas. Cada fila
// ocupa la altura REAL del remito (no una altura fija): uno de 2 productos es
// bajo y entran muchas filas por hoja; uno de 20 productos es alto y entran
// pocas.
//
// Reglas:
//  - Se acomodan en orden, de arriba hacia abajo, una fila por pedido.
//  - Un remito nunca se corta entre dos páginas, y las copias de un pedido
//    nunca se separan en hojas distintas: si la fila no entra completa en el
//    espacio que queda, pasa entera a la página siguiente.
//  - Cada remito mide `receiptWidth` mm de ancho (135 por defecto) y NO se
//    escala. Solo si una fila es más alta que la hoja entera, o si las
//    columnas no entran en el ancho útil, se reduce proporcionalmente lo
//    mínimo necesario (marcado con `scaled: true`).
//  - Nunca se genera una página vacía: una página existe solo si tiene algo.

// Configuración del layout de impresión. Para probar otro ancho de remito
// (130 / 135 / 138 mm) alcanza con cambiar `receiptWidth`: la captura se
// ajusta sola (ver captureWidthPx) y el tamaño físico de la letra no cambia.
export const PRINT_DEFAULTS = Object.freeze({
  pageWidth: 297, // mm, A4 horizontal
  pageHeight: 210,
  margin: 8, // mm; seguro para impresoras comunes (zona no imprimible ~5mm)
  columns: 2, // remitos por fila: las 2 copias de cada pedido
  columnGap: 4, // mm entre las dos copias (para cortar)
  rowGap: 4, // mm entre filas de pedidos
  receiptWidth: 135, // mm, ancho de cada remito (objetivo; entran 2 + separación en los ~281mm útiles)
  copies: 2 // una queda en el comercio, otra vuelve firmada con el repartidor
})

// Relación entre la captura y el papel: el remito se renderiza con
// `CSS_PX_PER_MM` px CSS por cada mm de papel, así 1px = 0,25mm y los tamaños
// de letra del CSS de impresión (.receipt-print-compact) equivalen a puntos
// reales: 13,5px -> 3,375mm -> ≈9,6pt. Cambiar el ancho en mm NO cambia el
// tamaño de la letra; solo cuánto texto entra por línea.
export const CSS_PX_PER_MM = 4

// Ancho (px CSS) con el que se captura cada remito para el PDF.
export function captureWidthPx(receiptWidth = PRINT_DEFAULTS.receiptWidth) {
  return Math.round(receiptWidth * CSS_PX_PER_MM)
}

export const PDF_RECEIPT_WIDTH_PX = captureWidthPx()

const EPSILON = 1e-6

// items: [{ width, height }] en cualquier unidad (solo importa la proporción);
// cada item es UN pedido (se colocan `copies` copias de él, juntas).
// Devuelve { pages: [[{ item, copy, x, y, width, height, scaled }]] } en mm,
// con el origen arriba a la izquierda de la hoja.
export function layoutReceipts(items, options = {}) {
  const { pageWidth, pageHeight, margin, columns, columnGap, rowGap, receiptWidth, copies } = { ...PRINT_DEFAULTS, ...options }

  if (!Number.isInteger(copies) || copies < 1) {
    throw new RangeError("La cantidad de copias debe ser un entero >= 1")
  }

  if (!Number.isInteger(columns) || columns < 1) {
    throw new RangeError("La cantidad de columnas debe ser un entero >= 1")
  }

  const usableWidth = pageWidth - 2 * margin
  const usableHeight = pageHeight - 2 * margin

  if (usableWidth <= 0 || usableHeight <= 0 || !(receiptWidth > 0)) {
    throw new RangeError("Los márgenes no dejan espacio útil en la hoja")
  }

  // Las copias de un pedido van lado a lado hasta `columns`; si hay más copias
  // que columnas, siguen en otra fila (siempre juntas en la misma página).
  const rowsInGroup = Math.ceil(copies / columns)

  // Ancho máximo de cada remito para que las columnas entren en la hoja.
  const maxWidthForColumns = (usableWidth - (columns - 1) * columnGap) / columns
  const baseWidth = Math.min(receiptWidth, maxWidthForColumns)
  const cellWidth = baseWidth
  const rowWidth = columns * cellWidth + (columns - 1) * columnGap
  const originX = margin + (usableWidth - rowWidth) / 2

  const pages = []
  let current = null
  let cursorY = 0
  const bottom = margin + usableHeight

  items.forEach((item) => {
    if (!(item.width > 0) || !(item.height > 0)) {
      throw new RangeError("Cada remito necesita ancho y alto positivos")
    }

    let width = baseWidth
    let height = (item.height / item.width) * width
    let scaled = width < receiptWidth - EPSILON

    // Alto del bloque completo del pedido (todas sus filas de copias).
    let groupHeight = rowsInGroup * height + (rowsInGroup - 1) * rowGap

    if (groupHeight > usableHeight + EPSILON) {
      const factor = usableHeight / groupHeight
      width *= factor
      height *= factor
      groupHeight = usableHeight
      scaled = true
    }

    const fitsInCurrentPage = current !== null && cursorY + groupHeight <= bottom + EPSILON

    if (!fitsInCurrentPage) {
      current = []
      pages.push(current)
      cursorY = margin
    }

    for (let copy = 0; copy < copies; copy++) {
      const row = Math.floor(copy / columns)
      const column = copy % columns

      current.push({
        item,
        copy,
        // cada remito centrado en su celda (importa solo si se escaló)
        x: originX + column * (cellWidth + columnGap) + (cellWidth - width) / 2,
        y: cursorY + row * (height + rowGap),
        width,
        height,
        scaled
      })
    }

    cursorY += groupHeight + rowGap
  })

  return { pages }
}
