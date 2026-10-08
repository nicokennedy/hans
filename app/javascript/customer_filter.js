// Lógica pura del selector de cliente del listado de pedidos (sin DOM), para poder
// testearla con `node --test`. El campo es un buscador con autocompletado
// (<datalist>): lo escrito se resuelve a un cliente solo si coincide exactamente
// con un nombre de la lista (sin importar mayúsculas, tildes ni espacios de más).

export function normalize(text) {
  return String(text ?? "")
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/\s+/g, " ")
    .trim()
}

// options: [{ name, id }]. Devuelve { id, valid }:
//   texto vacío            -> sin cliente (todos): id "", valid true
//   coincide con un nombre -> id del cliente, valid true
//   no coincide            -> id "", valid false (el formulario no se envía)
export function resolveCustomer(options, text) {
  const wanted = normalize(text)
  if (wanted === "") return { id: "", valid: true }

  const match = options.find((option) => normalize(option.name) === wanted)
  return match ? { id: String(match.id), valid: true } : { id: "", valid: false }
}
