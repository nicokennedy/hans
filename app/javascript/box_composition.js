// Lógica pura (sin DOM) del selector de sabores de una caja con contenido personalizable (Etapa 2).
// Espeja las reglas de Retail::BoxComposition del servidor, que vuelve a validar todo:
//  - cantidades enteras de 0 o más (nunca negativas);
//  - la suma nunca supera la capacidad de la caja;
//  - se puede agregar solo cuando la suma es EXACTAMENTE la capacidad.
// quantities: { idDeSabor: cantidad } (los ceros se pueden omitir). units: capacidad de la caja.

const clean = (value) => {
  const number = Number(value)
  return Number.isInteger(number) && number > 0 ? number : 0
}

export function total(quantities) {
  return Object.values(quantities || {}).reduce((sum, value) => sum + clean(value), 0)
}

export function remaining(quantities, units) {
  return Math.max(0, clean(units) - total(quantities))
}

export function isComplete(quantities, units) {
  return clean(units) > 0 && total(quantities) === clean(units)
}

export function canIncrement(quantities, units) {
  return remaining(quantities, units) > 0
}

export function canDecrement(quantities, id) {
  return clean((quantities || {})[id]) > 0
}

// Suma `step` unidades de un sabor sin pasarse de la capacidad.
export function increment(quantities, id, units, step = 1) {
  const next = { ...quantities }
  const add = Math.min(clean(step), remaining(quantities, units))
  if (add > 0) next[id] = clean(next[id]) + add
  return next
}

export function decrement(quantities, id, step = 1) {
  const next = { ...quantities }
  const value = Math.max(0, clean(next[id]) - clean(step))
  if (value === 0) delete next[id]
  else next[id] = value
  return next
}

// Completa lo que falta con un sabor (un toque para "toda la caja de almendra").
export function fill(quantities, id, units) {
  return increment(quantities, id, units, remaining(quantities, units))
}

// Texto del contador: "12 de 24 · faltan 12" / "24 de 24 · caja completa".
export function summary(quantities, units) {
  const chosen = total(quantities)
  const missing = remaining(quantities, units)
  const label = missing === 0 ? "caja completa" : `${missing === 1 ? "falta" : "faltan"} ${missing}`
  return `${chosen} de ${clean(units)} · ${label}`
}
