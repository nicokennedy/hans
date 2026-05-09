import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    const unavailableDays = JSON.parse(this.element.dataset.unavailableDays)

    window.flatpickr(this.element, {
      locale: "es",
      minDate: "today",
      dateFormat: "d/m/Y",

      disable: [
        function(date) {
          return unavailableDays.includes(date.getDay())
        }
      ]
    })
  }
}