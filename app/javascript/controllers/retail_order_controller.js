import { Controller } from "@hotwired/stimulus"
import { computeRetail } from "retail_totals"
import { formatPesos } from "payment_distribution"

// Formulario de pedido minorista: agrega productos de catálogo o manuales sin recargar y
// muestra subtotales, envío y total en vivo (exactos, ver retail_totals.js). El precio es
// SIEMPRE manual: nunca se completa solo. El servidor recalcula y valida todo al guardar.
export default class extends Controller {
  static targets = ["list", "productTemplate", "manualTemplate", "row", "shipping", "subtotal", "total", "errors"]

  connect() {
    this.recalculate()
  }

  addProduct(event) {
    event?.preventDefault()
    this.append(this.productTemplateTarget)
  }

  addManual(event) {
    event?.preventDefault()
    this.append(this.manualTemplateTarget)
  }

  append(template) {
    const html = template.innerHTML.replaceAll("NEW_INDEX", String(Date.now()))
    this.listTarget.insertAdjacentHTML("beforeend", html)
    this.recalculate()
    this.listTarget.querySelector("[data-retail-order-target='row']:last-child select, [data-retail-order-target='row']:last-child input[type=text]")?.focus()
  }

  remove(event) {
    event.preventDefault()
    event.target.closest("[data-retail-order-target='row']").remove()
    this.recalculate()
  }

  recalculate(event, { final = false } = {}) {
    const rows = this.rowTargets.map((row) => ({
      quantity: row.querySelector("[data-field='quantity']").value,
      price: row.querySelector("[data-field='price']").value,
      hasProduct: (row.querySelector("[data-field='product']")?.value || row.querySelector("[data-field='description']")?.value || "").trim() !== ""
    }))

    const result = computeRetail({ rows, shipping: this.hasShippingTarget ? this.shippingTarget.value : "" })

    this.rowTargets.forEach((row, index) => {
      row.querySelector("[data-field='subtotal']").textContent = `$${formatPesos(result.lines[index].subtotal)}`
    })
    this.subtotalTarget.textContent = `$${formatPesos(result.subtotal)}`
    this.totalTarget.textContent = `$${formatPesos(result.total)}`
    this.errorsTarget.innerHTML = ""
    // "Al menos un producto" solo se avisa al intentar guardar, no en un formulario recién abierto.
    if (!final) result.errors = result.errors.filter((message) => !message.startsWith("El pedido debe tener"))
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
    this.recalculate(null, { final: true })
    if (this.result && this.result.errors.length > 0) {
      event.preventDefault()
      this.errorsTarget.scrollIntoView({ behavior: "smooth", block: "center" })
    }
  }
}
