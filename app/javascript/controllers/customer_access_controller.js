import { Controller } from "@hotwired/stimulus"
import { matchesName, selectionSummary } from "product_visibility"

// Selector múltiple de clientes de un producto (Admin → Productos). Radio "Todos / Solo
// clientes seleccionados": el panel de clientes solo se muestra en el segundo caso. Buscador por
// nombre, lista de casillas (cómoda en celular), y los elegidos aparecen como etiquetas con ✕.
export default class extends Controller {
  static targets = ["panel", "radio", "search", "row", "chips", "summary", "empty"]

  connect() {
    this.toggle()
    this.render()
  }

  toggle() {
    const selected = this.radioTargets.find((radio) => radio.checked)?.value === "selected_customers"
    this.panelTarget.hidden = !selected
  }

  filter() {
    const query = this.searchTarget.value
    let visible = 0

    this.rowTargets.forEach((row) => {
      const show = matchesName(row.dataset.name, query)
      row.hidden = !show
      if (show) visible += 1
    })

    this.emptyTarget.hidden = visible > 0
  }

  change() {
    this.render()
  }

  remove(event) {
    event.preventDefault()
    const checkbox = this.rowTargets.find((row) => row.dataset.id === String(event.params.id))?.querySelector("input[type=checkbox]")
    if (checkbox) checkbox.checked = false
    this.render()
  }

  render() {
    const checked = this.rowTargets.filter((row) => row.querySelector("input[type=checkbox]").checked)
    this.summaryTarget.textContent = selectionSummary(checked.length)
    this.chipsTarget.innerHTML = ""

    checked.forEach((row) => {
      const chip = document.createElement("span")
      chip.className = "badge text-bg-dark d-inline-flex align-items-center gap-1 me-1 mb-1"
      chip.append(row.dataset.name)

      const button = document.createElement("button")
      button.type = "button"
      button.className = "btn-close btn-close-white ms-1"
      button.style.fontSize = "0.6rem"
      button.setAttribute("aria-label", `Quitar ${row.dataset.name}`)
      button.dataset.action = "customer-access#remove"
      button.dataset.customerAccessIdParam = row.dataset.id
      chip.appendChild(button)
      this.chipsTarget.appendChild(chip)
    })
  }
}
