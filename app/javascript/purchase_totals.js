// Cálculo puro (sin DOM) de subtotales y total de una compra, EXACTO: la cantidad se
// maneja en milésimas enteras y los importes en centavos, con BigInt para el producto
// (nunca floats). Espeja a Finance::Money.line_subtotal_cents del servidor, que vuelve a
// calcular todo al guardar.
// Mismo parser de pesos que payment_distribution.js (se repite a propósito: los módulos
// puros no se importan entre sí para poder testearlos con `node --test` sin importmap).
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

// "2,5" / "2.5" / "1.250,5" -> milésimas enteras (2500n); inválido o ambiguo -> null.
// "1.250" / "1,250" es ambiguo (1,25 o 1250) y se rechaza, igual que en el servidor.
export function parseQuantityThousandths(text) {
  let value = String(text ?? "").replace(/\s+/g, "")
  if (value === "" || /[^\d.,]/.test(value)) return null

  if (value.includes(",") && value.includes(".")) {
    const decimal = value.lastIndexOf(",") > value.lastIndexOf(".") ? "," : "."
    const thousands = decimal === "," ? "." : ","
    const [integer, fraction, ...rest] = value.split(decimal)
    if (rest.length > 0 || !new RegExp(`^\\d{1,3}(\\${thousands}\\d{3})*$`).test(integer)) return null
    value = `${integer.split(thousands).join("")}.${fraction}`
  } else {
    const separator = value.includes(",") ? "," : value.includes(".") ? "." : null

    if (separator && value.split(separator).length > 2) {
      if (!new RegExp(`^\\d{1,3}(\\${separator}\\d{3})+$`).test(value)) return null
      value = value.split(separator).join("")
    } else if (separator) {
      const [integer, decimals] = value.split(separator)
      if (decimals.length === 3 && /^[1-9]\d{0,2}$/.test(integer)) return null
      value = `${integer}.${decimals}`
    }
  }

  if (!/^\d+(\.\d{1,3})?$/.test(value)) return null
  const [integer, decimals = ""] = value.split(".")
  return BigInt(integer) * 1000n + BigInt(decimals.padEnd(3, "0"))
}

// milésimas x centavos / 1000, mitad hacia arriba.
export function lineSubtotalCents(quantityThousandths, unitPriceCents) {
  const product = quantityThousandths * BigInt(unitPriceCents)
  return Number((product + 500n) / 1000n)
}

// Importe con signo opcional (para "otros ajustes").
export function parseSignedPesos(text) {
  const value = String(text ?? "").trim()
  if (value.startsWith("-")) {
    const cents = parsePesos(value.slice(1))
    return cents === null ? null : -cents
  }
  return parsePesos(value)
}

// rows: [{ quantity: texto, price: texto }]. blank -> 0 en descuento/impuestos/ajustes.
export function computePurchase({ rows, discount = "", taxes = "", adjustments = "" }) {
  const errors = []
  const lines = rows.map((row, index) => {
    const empty = String(row.quantity ?? "").trim() === "" && String(row.price ?? "").trim() === ""
    if (empty) return { subtotal: 0, empty: true }

    const quantity = parseQuantityThousandths(row.quantity)
    const price = parsePesos(row.price)
    if (quantity === null) errors.push(`Ítem ${index + 1}: cantidad inválida.`)
    if (price === null) errors.push(`Ítem ${index + 1}: precio inválido.`)
    return quantity === null || price === null ? { subtotal: 0, invalid: true } : { subtotal: lineSubtotalCents(quantity, price) }
  })

  const optional = (text, label, signed = false) => {
    if (String(text ?? "").trim() === "") return 0
    const cents = signed ? parseSignedPesos(text) : parsePesos(text)
    if (cents === null) errors.push(`${label} no es un importe válido.`)
    return cents ?? 0
  }

  const subtotal = lines.reduce((sum, line) => sum + line.subtotal, 0)
  const discountCents = optional(discount, "El descuento")
  const taxesCents = optional(taxes, "Los impuestos")
  const adjustmentsCents = optional(adjustments, "Otros ajustes", true)
  const total = subtotal - discountCents + taxesCents + adjustmentsCents

  if (total <= 0 && lines.some((line) => !line.empty)) errors.push("El total de la compra debe ser mayor a cero.")
  return { lines, subtotal, total, errors: [...new Set(errors)] }
}
