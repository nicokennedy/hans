// Lógica pura (sin DOM) de la visibilidad de productos por cliente, para testearla con
// `node --test`. Solo es ayuda visual: el servidor valida siempre (Product#available_to?).

export function normalize(text) {
  return String(text ?? "")
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/\s+/g, " ")
    .trim()
}

// option: { visibility: "all" | "selected", customerIds: ["1", "2"] }.
// Un producto "selected" solo está disponible para sus clientes; sin cliente elegido, solo los públicos.
export function isAvailableTo(option, customerId) {
  if (option.visibility !== "selected") return true

  const id = String(customerId ?? "")
  return id !== "" && option.customerIds.map(String).includes(id)
}

// Buscador del selector de clientes del producto: coincidencia por nombre sin importar
// mayúsculas ni tildes. Consulta vacía -> todos.
export function matchesName(name, query) {
  const wanted = normalize(query)
  return wanted === "" || normalize(name).includes(wanted)
}

export function selectionSummary(count) {
  if (count === 0) return "Ningún cliente seleccionado"
  return count === 1 ? "1 cliente seleccionado" : `${count} clientes seleccionados`
}
