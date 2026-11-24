import { Controller } from "@hotwired/stimulus"

// Muestra u oculta uno o varios bloques según un checkbox (ej. "Registrar el pago ahora" o
// "Permitir personalizar el contenido"). Los bloques que se agregan después (filas nuevas de un
// formulario) toman el estado actual al aparecer.
export default class extends Controller {
  static targets = ["checkbox", "body"]

  connect() {
    this.toggle()
  }

  toggle() {
    this.bodyTargets.forEach((body) => this.apply(body))
  }

  bodyTargetConnected(body) {
    this.apply(body)
  }

  apply(body) {
    if (this.hasCheckboxTarget) body.hidden = !this.checkboxTarget.checked
  }
}
