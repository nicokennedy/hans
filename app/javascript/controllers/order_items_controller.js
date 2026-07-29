import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["list", "template"]

  add(event) {
    event.preventDefault()
    this.listTarget.appendChild(this.templateTarget.content.cloneNode(true))
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
}
