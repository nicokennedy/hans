import { Controller } from "@hotwired/stimulus"

// Selector de tamaño del detalle de producto de la tienda: al elegir una variante muestra su precio
// y su descripción propia enseguida (sin recargar) y ajusta el máximo de la cantidad al stock disponible. El precio que vale
// es siempre el del servidor: esto es solo visual.
// En el celular muestra una barra fija con precio y "Agregar" mientras el botón principal no está a la vista.
export default class extends Controller {
  static targets = ["price", "quantity", "description", "label", "submit", "buybar"]

  connect() {
    if (!this.hasBuybarTarget || !this.hasSubmitTarget || !("IntersectionObserver" in window)) return
    this.observer = new IntersectionObserver(([entry]) => {
      // Visible solo cuando el botón principal quedó fuera de la pantalla.
      const show = !entry.isIntersecting
      this.buybarTarget.classList.toggle("is-visible", show)
      this.buybarTarget.setAttribute("aria-hidden", String(!show))
    })
    this.observer.observe(this.submitTarget)
  }

  disconnect() {
    if (this.observer) this.observer.disconnect()
  }

  select(event) {
    const input = event.target
    if (input.dataset.price) {
      this.priceTargets.forEach((el) => {
        el.textContent = input.dataset.price
        el.classList.remove("is-updated")
        void el.offsetWidth // reinicia la animación
        el.classList.add("is-updated")
      })
    }
    if (this.hasLabelTarget && input.dataset.label) this.labelTarget.textContent = input.dataset.label
    this.descriptionTargets.forEach((el) => { el.hidden = el.dataset.variantId !== input.value })
    if (this.hasQuantityTarget && input.dataset.max) {
      const max = parseInt(input.dataset.max, 10)
      this.quantityTarget.max = max
      if ((parseInt(this.quantityTarget.value, 10) || 1) > max) this.quantityTarget.value = max
    }
  }
}
