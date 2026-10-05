import { Controller } from "@hotwired/stimulus"
import { matches } from "stock_search"

// Buscador de /admin/stock. Filtra en el navegador las filas que el servidor
// ya renderizó (son pocas): respuesta instantánea al tipear, sin requests y
// sin tocar la conciliación ni ningún dato. Solo muestra/oculta filas.
export default class extends Controller {
  static targets = ["input", "row", "empty", "clear", "counter"]
  static values = { total: Number }

  connect() {
    // Si el navegador restauró un texto al volver atrás, se aplica el filtro.
    this.filter()
  }

  filter() {
    const query = this.inputTarget.value
    let visible = 0

    this.rowTargets.forEach((row) => {
      const show = matches(row.dataset.stockSearchName, query)
      row.hidden = !show
      row.classList.toggle("d-none", !show)
      if (show) visible += 1
    })

    const searching = query.trim() !== ""
    this.clearTarget.hidden = !searching
    this.emptyTarget.hidden = !(searching && visible === 0)
    this.counterTarget.hidden = !(searching && visible > 0)
    this.counterTarget.textContent = `Mostrando ${visible} de ${this.rowTargets.length}`
  }

  clear() {
    this.inputTarget.value = ""
    this.filter()
    this.inputTarget.focus()
  }

  // Enter en el buscador no debe disparar nada (no hay botón "Buscar").
  preventSubmit(event) {
    event.preventDefault()
  }
}
