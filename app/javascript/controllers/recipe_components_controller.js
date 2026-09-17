import { Controller } from "@hotwired/stimulus"

// Agrega/quita filas de componente en las pantallas de alta de Preparation
// y ProductRecipe (mismo patrón que order_items_controller.js: <template>
// + clonado, sin ningún gem de forms anidados).
export default class extends Controller {
  static targets = ["list", "template"]

  add(event) {
    event.preventDefault()
    this.listTarget.appendChild(this.templateTarget.content.cloneNode(true))
  }

  remove(event) {
    event.preventDefault()
    event.target.closest(".recipe-component-row").remove()
  }
}
