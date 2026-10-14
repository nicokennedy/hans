import { Controller } from "@hotwired/stimulus"
import { isAvailableTo } from "product_visibility"

export default class extends Controller {
  static targets = ["list", "template", "customer", "exception", "exceptionBox"]

  connect() {
    this.applyVisibility()
  }

  add(event) {
    event.preventDefault()
    this.listTarget.appendChild(this.templateTarget.content.cloneNode(true))
    this.applyVisibility()
  }

  // Al elegir un producto, precarga su precio de lista (en pesos, sin
  // decimales) en el input de precio unitario de la misma fila. Siempre
  // sobrescribe lo que hubiera ahí: el usuario recién eligió otro producto,
  // así que el precio anterior ya no corresponde.
  fillPrice(event) {
    const select = event.target
    const option = select.options[select.selectedIndex]
    const priceAmount = option && option.dataset.priceAmount

    if (priceAmount === undefined || priceAmount === "") return

    const row = select.closest(".order-item-row")
    const priceInput = row && row.querySelector(".unit-price-input")

    if (priceInput) priceInput.value = priceAmount
  }

  // Visibilidad de productos por cliente: por defecto solo se ofrecen los habilitados para el
  // cliente elegido (los restringidos a otros se ocultan; el ya elegido en una línea existente
  // siempre se conserva). Con la excepción administrativa tildada se muestran todos, marcando
  // los no habilitados. Es solo ayuda visual: el servidor valida igual.
  applyVisibility() {
    if (!this.hasCustomerTarget) return

    const customerId = this.customerTarget.value
    const showAll = this.hasExceptionTarget && this.exceptionTarget.checked

    this.element.querySelectorAll("select[name*='product_id']").forEach((select) => {
      Array.from(select.options).forEach((option) => {
        if (option.value === "") return

        const available = isAvailableTo({ visibility: option.dataset.visibility, customerIds: (option.dataset.customerIds || "").split(",").filter(Boolean) }, customerId)
        const keep = available || option.selected || showAll

        option.hidden = !keep
        option.disabled = !keep
        option.textContent = available ? option.dataset.name : `${option.dataset.name} (no habilitado para este cliente)`
      })
    })
  }
}
