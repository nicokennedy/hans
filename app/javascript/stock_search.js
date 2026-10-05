// Lógica pura del buscador de /admin/stock (sin DOM), para poder testearla
// con `node --test`. Compara sin mayúsculas/minúsculas ni tildes, por
// coincidencia parcial; varias palabras se buscan todas, en cualquier orden.

export function normalize(text) {
  return String(text ?? "")
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/\s+/g, " ")
    .trim()
}

export function matches(name, query) {
  const terms = normalize(query).split(" ").filter(Boolean)
  if (terms.length === 0) return true

  const haystack = normalize(name)
  return terms.every((term) => haystack.includes(term))
}
