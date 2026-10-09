import { Controller } from "@hotwired/stimulus"

// Muestra u oculta un bloque según un checkbox (ej. "Registrar el pago ahora").
export default class extends Controller {
  static targets = ["checkbox", "body"]

  connect() {
    this.toggle()
  }

  toggle() {
    this.bodyTarget.hidden = !this.checkboxTarget.checked
  }
}
