import { Controller } from "@hotwired/stimulus"

// Selector de tamaño del detalle de producto de la tienda: al elegir una variante muestra su precio
// y su descripción propia enseguida (sin recargar) y ajusta el máximo de la cantidad al stock disponible. El precio que vale
// es siempre el del servidor: esto es solo visual.
export default class extends Controller {
  static targets = ["price", "quantity", "description"]

  select(event) {
    const input = event.target
    if (this.hasPriceTarget && input.dataset.price) this.priceTarget.textContent = input.dataset.price
    this.descriptionTargets.forEach((el) => { el.hidden = el.dataset.variantId !== input.value })
    if (this.hasQuantityTarget && input.dataset.max) {
      const max = parseInt(input.dataset.max, 10)
      this.quantityTarget.max = max
      if ((parseInt(this.quantityTarget.value, 10) || 1) > max) this.quantityTarget.value = max
    }
  }
}
