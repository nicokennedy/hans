import { Controller } from "@hotwired/stimulus"

// Botón flotante de WhatsApp de la tienda (consultas generales). Siempre visible al hacer scroll,
// salvo mientras quedaría encima de controles de compra: sabores de una caja, cantidades, presentaciones,
// "Agregar al carrito", "Continuar con el pedido", los campos del checkout o "Finalizar pedido por WhatsApp". En ese momento se
// corre (queda semitransparente y no se puede tocar) y vuelve cuando esos controles salen de la zona
// inferior de la pantalla. Arriba de la barra fija de "Agregar" se ubica por CSS.
const AVOID = [
  ".store-box-flavor", ".store-add-row", ".store-variant-options", ".store-stepper",
  "#store-submit", "#store-go-checkout", ".store-line-actions", ".store-add-submit",
  // Checkout: campos, modalidades, zonas y formas de pago.
  ".store-checkout input:not([type=hidden])", ".store-checkout select", ".store-checkout textarea", ".store-option", ".store-zone"
].join(", ")

export default class extends Controller {
  connect() {
    if (!("IntersectionObserver" in window)) return
    this.covering = new Set()
    // Solo cuenta la franja inferior de la pantalla, donde está el botón.
    this.observer = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) this.covering.add(entry.target)
        else this.covering.delete(entry.target)
      })
      this.element.classList.toggle("is-tucked", this.covering.size > 0)
    }, { rootMargin: "-74% 0px 0px 0px" })
    document.querySelectorAll(AVOID).forEach((el) => this.observer.observe(el))
  }

  disconnect() {
    this.observer?.disconnect()
  }
}
