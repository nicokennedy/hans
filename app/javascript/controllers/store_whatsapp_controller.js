import { Controller } from "@hotwired/stimulus"

// "Pedido recibido": la primera vez que se muestra (recién registrado el pedido) intenta abrir
// WhatsApp en otra pestaña con el mensaje armado. Muchos navegadores (sobre todo en celulares)
// bloquean la apertura automática: entonces se avisa y queda el botón verde, que siempre funciona.
// Recargar o volver a esta página no lo abre de nuevo ni crea otro pedido.
export default class extends Controller {
  static targets = ["blocked"]
  static values = { url: String, auto: Boolean }

  connect() {
    if (!this.autoValue || !this.urlValue) return
    this.autoValue = false
    let opened = null
    try {
      opened = window.open(this.urlValue, "_blank")
      if (opened) opened.opener = null
    } catch (_error) {
      opened = null
    }
    if (!opened && this.hasBlockedTarget) this.blockedTarget.hidden = false
  }
}
