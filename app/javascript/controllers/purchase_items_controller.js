import { Controller } from "@hotwired/stimulus"
import { computePurchase } from "purchase_totals"
import { formatPesos } from "payment_distribution"

// Formulario de compra: agrega y quita filas de ítems sin recargar y muestra subtotales y
// total en vivo (exactos, ver purchase_totals.js). El servidor recalcula todo al guardar.
export default class extends Controller {
  static targets = ["list", "template", "row", "quantity", "price", "subtotal", "discount", "taxes", "adjustments", "subtotalTotal", "total", "errors"]

  connect() {
    this.recalculate()
  }

  add(event) {
    event?.preventDefault()
    const html = this.templateTarget.innerHTML.replaceAll("NEW_INDEX", String(Date.now()))
    this.listTarget.insertAdjacentHTML("beforeend", html)
    this.recalculate()
    this.listTarget.querySelector(".purchase-item-row:last-child input[type=text]")?.focus()
  }

  remove(event) {
    event.preventDefault()
    const row = event.target.closest("[data-purchase-items-target='row']")
    if (this.rowTargets.length > 1) {
      row.remove()
    } else {
      row.querySelectorAll("input[type=text]").forEach((input) => { input.value = "" })
    }
    this.recalculate()
  }

  recalculate() {
    const rows = this.rowTargets.map((row) => ({
      quantity: row.querySelector("[data-purchase-items-target='quantity']").value,
      price: row.querySelector("[data-purchase-items-target='price']").value
    }))

    const result = computePurchase({
      rows,
      discount: this.hasDiscountTarget ? this.discountTarget.value : "",
      taxes: this.hasTaxesTarget ? this.taxesTarget.value : "",
      adjustments: this.hasAdjustmentsTarget ? this.adjustmentsTarget.value : ""
    })

    this.rowTargets.forEach((row, index) => {
      row.querySelector("[data-purchase-items-target='subtotal']").textContent = `$${formatPesos(result.lines[index].subtotal)}`
    })
    this.subtotalTotalTarget.textContent = `$${formatPesos(result.subtotal)}`
    this.totalTarget.textContent = `$${formatPesos(result.total)}`
    this.errorsTarget.innerHTML = ""
    result.errors.forEach((message) => {
      const item = document.createElement("div")
      item.textContent = message
      this.errorsTarget.appendChild(item)
    })
    this.errorsTarget.hidden = result.errors.length === 0
    this.result = result
  }

  // El servidor valida igual; esto evita enviar un formulario con errores evidentes.
  prepare(event) {
    this.recalculate()
    if (this.result && this.result.errors.length > 0) {
      event.preventDefault()
      this.errorsTarget.scrollIntoView({ behavior: "smooth", block: "center" })
    }
  }
}
