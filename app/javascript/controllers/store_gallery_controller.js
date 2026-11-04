import { Controller } from "@hotwired/stimulus"

// Galería del detalle de producto: tocar una miniatura muestra esa foto grande.
export default class extends Controller {
  static targets = ["main", "thumb"]

  show(event) {
    const button = event.currentTarget
    this.mainTarget.src = button.dataset.src
    this.thumbTargets.forEach((thumb) => thumb.classList.toggle("is-active", thumb === button))
  }
}
