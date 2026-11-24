import { Controller } from "@hotwired/stimulus"
import { total, isComplete, summary } from "box_composition"

// Caja con contenido personalizable en el formulario de pedidos minoristas del administrador.
// Muestra los sabores del producto elegido y un contador "12 de 24 · faltan 12". Cambiar de
// presentación NO borra lo cargado: si las unidades ya no coinciden, el contador lo marca y el
// servidor pide completarla de nuevo (Retail::BoxComposition valida igual que en la tienda).
export default class extends Controller {
  static targets = ["variant", "group", "flavor", "counter", "price"]
  static values = { units: Number }

  connect() {
    this.previousPrice = this.variantTarget.selectedOptions[0]?.dataset.price || ""
    this.recount()
  }

  variantChanged() {
    const option = this.variantTarget.selectedOptions[0]
    this.unitsValue = Number(option?.dataset.units || 0)
    const productId = option?.dataset.productId
    this.groupTargets.forEach((group) => {
      const visible = group.dataset.productId === productId
      group.hidden = !visible
      group.querySelectorAll("input").forEach((input) => { input.disabled = !visible })
    })
    // Precio sugerido: el de la presentación, solo si el campo estaba vacío o tenía el precio anterior.
    if (this.hasPriceTarget && option?.dataset.price) {
      const current = this.priceTarget.value.trim()
      if (current === "" || current === this.previousPrice) this.priceTarget.value = option.dataset.price
      this.previousPrice = option.dataset.price
    }
    this.recount()
  }

  recount() {
    if (!this.hasCounterTarget) return
    if (!this.unitsValue) {
      this.counterTarget.textContent = this.variantTarget.value ? "La presentación no tiene unidades configuradas" : "Elegí la caja"
      this.counterTarget.className = "small fw-bold text-muted"
      return
    }
    const quantities = {}
    this.flavorTargets.filter((input) => !input.disabled).forEach((input) => { quantities[input.name] = Number(input.value) })
    const chosen = total(quantities)
    const units = this.unitsValue
    let text = summary(quantities, units)
    if (chosen > units) text = `${chosen} de ${units} · sobran ${chosen - units}`
    this.counterTarget.textContent = text
    this.counterTarget.className = `small fw-bold ${isComplete(quantities, units) ? "text-success" : "text-danger"}`
  }
}
