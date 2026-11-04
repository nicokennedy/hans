import { Controller } from "@hotwired/stimulus"

// Checkout de la tienda: muestra los campos de la modalidad elegida (retiro o envío) y actualiza el
// resumen (envío y total) como ayuda visual. Los importes reales los calcula siempre el servidor.
export default class extends Controller {
  static targets = ["pickup", "delivery", "shipping", "total"]
  static values = { subtotal: Number }

  connect() {
    this.update()
    const errors = document.getElementById("store-checkout-errors")
    if (errors) errors.focus()
  }

  kindChanged() {
    this.update()
  }

  zoneChanged() {
    this.update()
  }

  get kind() {
    const checked = this.element.querySelector("input[name='delivery_kind']:checked")
    return checked ? checked.value : "pickup"
  }

  update() {
    const delivery = this.kind === "delivery"
    this.toggle(this.pickupTarget, !delivery)
    this.toggle(this.deliveryTarget, delivery)

    let shipping = 0
    let shippingText = "Gratis"
    if (delivery) {
      const zone = this.element.querySelector("input[name='delivery_zone_id']:checked")
      if (zone) {
        shipping = parseInt(zone.dataset.price, 10) || 0
        shippingText = this.money(shipping)
      } else {
        shippingText = "Elegí la zona"
      }
    }
    this.shippingTarget.textContent = shippingText
    this.totalTarget.textContent = this.money(this.subtotalValue + shipping)
  }

  // Los campos de la modalidad oculta quedan deshabilitados: no se validan ni se envían.
  toggle(section, visible) {
    section.hidden = !visible
    section.querySelectorAll("input, select, textarea").forEach((field) => { field.disabled = !visible })
  }

  money(cents) {
    const pesos = cents / 100
    const options = Number.isInteger(pesos) ? { maximumFractionDigits: 0 } : { minimumFractionDigits: 2, maximumFractionDigits: 2 }
    return "$" + pesos.toLocaleString("es-AR", options)
  }
}
