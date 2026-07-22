import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["list", "template"]

  add(event) {
    event.preventDefault()
    this.listTarget.appendChild(this.templateTarget.content.cloneNode(true))
  }
}
