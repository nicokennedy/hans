// Lógica pura de la distribución de un pago de cuenta corriente (sin DOM), testeable con
// `node --test`. Todo en CENTAVOS ENTEROS (nunca floats). Espeja a
// CustomerAccounts::Money y CustomerAccounts::Distribution del servidor, que de todos
// modos revalida todo al confirmar.

// "300000", "300.000", "$ 300.000", "1.500,50" -> centavos. Texto ambiguo o inválido -> null.
export function parsePesos(text) {
  const value = String(text ?? "").replace(/\$/g, "").replace(/\s+/g, "")
  if (value === "") return null

  if (/^\d+$/.test(value) || /^\d{1,3}([.,]\d{3})+$/.test(value)) {
    return Number(value.replace(/[.,]/g, "")) * 100
  }

  let match = value.match(/^(\d{1,3}(?:\.\d{3})*|\d+),(\d{1,2})$/)
  if (match) return Number(match[1].replace(/\./g, "")) * 100 + Number(match[2].padEnd(2, "0"))

  match = value.match(/^(\d+)\.(\d{1,2})$/)
  if (match) return Number(match[1]) * 100 + Number(match[2].padEnd(2, "0"))

  return null
}

// 30000000 -> "300.000" ; 150050 -> "1.500,50"
export function formatPesos(cents) {
  const sign = cents < 0 ? "-" : ""
  const absolute = Math.abs(cents)
  const whole = Math.floor(absolute / 100)
  const rest = absolute % 100
  const digits = String(whole).replace(/\B(?=(\d{3})+(?!\d))/g, ".")
  return rest === 0 ? `${sign}${digits}` : `${sign}${digits},${String(rest).padStart(2, "0")}`
}

// orders: [{ id, balance }] YA ordenados (fecha de entrega, luego creación). Reparte el
// importe sin superar el saldo de cada pedido ni el total recibido.
export function suggest(orders, amountCents) {
  let remaining = Math.max(Number.isInteger(amountCents) ? amountCents : 0, 0)
  const allocations = {}

  for (const order of orders) {
    if (remaining <= 0) break
    if (!(order.balance > 0)) continue

    const applied = Math.min(order.balance, remaining)
    allocations[order.id] = applied
    remaining -= applied
  }

  return { allocations, unapplied: remaining }
}

// rows: [{ id, balance, cents }] (cents = lo que el usuario puso; null si está vacío/ inválido
// se informa en `invalid`). Devuelve los totales de la vista previa y los errores.
export function summarize({ amountCents, rows, pendingTotal }) {
  const errors = []
  let applied = 0

  rows.forEach((row) => {
    if (row.invalid) {
      errors.push(`El importe del pedido ${row.label ?? row.id} no es válido.`)
      return
    }

    const cents = row.cents ?? 0
    if (cents < 0) errors.push("No se permiten importes negativos.")
    if (cents > row.balance) errors.push(`El pedido ${row.label ?? row.id} no puede superar su saldo de $${formatPesos(row.balance)}.`)
    applied += Math.max(cents, 0)
  })

  const received = Number.isInteger(amountCents) ? amountCents : 0
  if (applied > received) errors.push(`Lo distribuido ($${formatPesos(applied)}) supera el monto recibido ($${formatPesos(received)}).`)

  const unapplied = received - applied
  return {
    received,
    applied,
    unapplied,
    credit: Math.max(unapplied, 0),
    pendingAfter: Math.max(pendingTotal - applied, 0),
    errors: [...new Set(errors)],
    valid: errors.length === 0
  }
}
