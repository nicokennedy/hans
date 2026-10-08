import { Controller } from "@hotwired/stimulus"
import { resolveCustomer } from "customer_filter"

// Selector de cliente con búsqueda del filtro de /admin/orders: escribir filtra la
// lista (datalist nativo) y al elegir un nombre se completa el customer_id oculto.
// Un texto que no es un cliente de la lista no se envía (se avisa en el campo).
export default class extends Controller {
  static targets = ["input", "hidden", "list"]

  connect() {
    this.sync()
  }

  sync() {
    const { id, valid } = resolveCustomer(this.options(), this.inputTarget.value)

    this.hiddenTarget.value = id
    this.inputTarget.setCustomValidity(valid ? "" : "Elegí un cliente de la lista o dejá el campo vacío.")
  }

  validate(event) {
    this.sync()

    if (!this.inputTarget.checkValidity()) {
      event.preventDefault()
      this.inputTarget.reportValidity()
    }
  }

  options() {
    return Array.from(this.listTarget.options).map((option) => ({ name: option.value, id: option.dataset.id }))
  }
}
