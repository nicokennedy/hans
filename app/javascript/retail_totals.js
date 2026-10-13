// Cálculo puro (sin DOM) de subtotales y total de un pedido minorista, EXACTO: cantidades
// enteras e importes en centavos enteros (nunca floats). Espeja a Retail::SaveOrder del
// servidor, que vuelve a calcular y validar todo al guardar.
// Mismo parser de pesos que purchase_totals.js (se repite a propósito: los módulos puros no
// se importan entre sí para poder testearlos con `node --test` sin importmap).
export const MAX_QUANTITY = 100000
export const MAX_CENTS = 2000000000

export function parsePesos(text) {
  const value = String(text ?? "").replace(/\$/g, "").replace(/\s+/g, "")
  if (value === "") return null

  if (/^\d+$/.test(value) || /^\d{1,3}([.,]\d{3})+$/.test(value)) return Number(value.replace(/[.,]/g, "")) * 100

  let match = value.match(/^(\d{1,3}(?:\.\d{3})*|\d+),(\d{1,2})$/)
  if (match) return Number(match[1].replace(/\./g, "")) * 100 + Number(match[2].padEnd(2, "0"))

  match = value.match(/^(\d+)\.(\d{1,2})$/)
  if (match) return Number(match[1]) * 100 + Number(match[2].padEnd(2, "0"))

  return null
}

// Cantidad entera > 0 (hasta MAX_QUANTITY); cualquier otra cosa -> null.
export function parseQuantity(text) {
  const value = String(text ?? "").trim()
  if (!/^\d{1,9}$/.test(value)) return null

  const quantity = Number(value)
  return quantity > 0 && quantity <= MAX_QUANTITY ? quantity : null
}

// rows: [{ quantity: texto, price: texto }]; shipping: texto (vacío = 0).
// Una fila totalmente vacía se ignora (igual que el servidor).
export function computeRetail({ rows, shipping = "" }) {
  const errors = []
  let counted = 0

  const lines = rows.map((row, index) => {
    const empty = String(row.quantity ?? "").trim() === "" && String(row.price ?? "").trim() === "" && !row.hasProduct
    if (empty) return { subtotal: 0, empty: true }

    counted += 1
    const quantity = parseQuantity(row.quantity)
    const price = String(row.price ?? "").trim() === "" ? null : parsePesos(row.price)
    if (quantity === null) errors.push(`Ítem ${index + 1}: la cantidad debe ser un entero mayor a cero.`)
    if (price === null) errors.push(`Ítem ${index + 1}: el precio es obligatorio y debe ser un importe válido (puede ser 0).`)
    if (quantity === null || price === null) return { subtotal: 0, invalid: true }

    const subtotal = quantity * price
    if (subtotal > MAX_CENTS) errors.push(`Ítem ${index + 1}: el importe de la línea es demasiado alto.`)
    return { subtotal }
  })

  let shippingCents = 0
  if (String(shipping ?? "").trim() !== "") {
    shippingCents = parsePesos(shipping)
    if (shippingCents === null) {
      errors.push("El envío no es un importe válido.")
      shippingCents = 0
    }
  }

  const subtotal = lines.reduce((sum, line) => sum + line.subtotal, 0)
  const total = subtotal + shippingCents
  if (counted === 0) errors.push("El pedido debe tener al menos un producto.")
  if (total > MAX_CENTS) errors.push("El total supera el máximo permitido.")

  return { lines, subtotal, shipping: shippingCents, total, errors: [...new Set(errors)] }
}
