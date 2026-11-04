import { Controller } from "@hotwired/stimulus"

// Selector de cantidad (−/+) de la tienda. Con autosubmit (carrito) guarda el cambio enseguida.
export default class extends Controller {
  static targets = ["input"]
  static values = { autosubmit: Boolean }

  increment() {
    this.step(1)
  }

  decrement() {
    this.step(-1)
  }

  step(delta) {
    const input = this.inputTarget
    const min = parseInt(input.min, 10) || 1
    const max = parseInt(input.max, 10) || 99
    const current = parseInt(input.value, 10) || min
    const next = Math.min(max, Math.max(min, current + delta))
    if (next === current) return
    input.value = next
    if (this.autosubmitValue) this.submit()
  }

  submit() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.element.requestSubmit(), 350)
  }
}
