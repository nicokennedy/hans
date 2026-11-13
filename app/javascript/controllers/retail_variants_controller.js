import { Controller } from "@hotwired/stimulus"

// Formulario de producto minorista: agrega y quita filas de variantes (tamaños o presentaciones) sin
// recargar. Las variantes guardadas no se quitan acá: se marcan "Eliminar" o se deshabilitan.
export default class extends Controller {
  static targets = ["list", "template", "row"]

  add(event) {
    event?.preventDefault()
    const html = this.templateTarget.innerHTML.replaceAll("NEW_INDEX", String(Date.now()))
    this.listTarget.insertAdjacentHTML("beforeend", html)
    const rows = this.rowTargets
    const last = rows[rows.length - 1]
    const position = last?.querySelector("input[name$='[position]']")
    if (position && !position.value) position.value = rows.length
    last?.querySelector("input[name$='[name]']")?.focus()
  }

  remove(event) {
    event.preventDefault()
    event.target.closest("[data-retail-variants-target='row']")?.remove()
  }
}
