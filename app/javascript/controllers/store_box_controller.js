import { Controller } from "@hotwired/stimulus"
import { total, remaining, isComplete, increment, decrement, fill, summary } from "box_composition"

// Selector de sabores de una caja con contenido personalizable (detalle de producto de la tienda).
// Va en el formulario "Agregar al carrito":
//  - controles − y + por sabor, contador "12 de 24 · faltan 12" y barra de progreso;
//  - "Completar" llena lo que falta con un sabor (toda la caja de almendra en un toque);
//  - nunca baja de 0 ni supera la capacidad; "Agregar al carrito" se habilita solo con la caja exacta;
//  - al cambiar de variante (caja x 8 / x 12 / x 24) la selección vuelve a cero y se avisa.
// Es solo ayuda: el servidor valida todo de nuevo (Retail::BoxComposition).
export default class extends Controller {
  static targets = ["flavor", "count", "input", "counter", "progress", "notice", "minus", "plus", "fill", "units", "reset"]
  static values = { units: Number }

  connect() {
    const checked = this.element.querySelector("input[name='variant_id']:checked")
    if (checked?.dataset.units) this.unitsValue = Number(checked.dataset.units)
    this.quantities = {}
    this.inputTargets.forEach((input) => {
      const value = parseInt(input.value, 10)
      if (value > 0) this.quantities[input.dataset.flavorId] = value
    })
    this.render()
  }

  increment(event) {
    this.change(increment(this.quantities, this.idFrom(event), this.unitsValue))
  }

  decrement(event) {
    this.change(decrement(this.quantities, this.idFrom(event)))
  }

  fill(event) {
    this.change(fill(this.quantities, this.idFrom(event), this.unitsValue))
  }

  reset(event) {
    event?.preventDefault()
    this.change({})
    this.say("Vaciaste la caja.")
  }

  // Otra presentación (caja x 8 / x 12 / x 24): la composición anterior ya no sirve.
  variantChanged(event) {
    const units = Number(event.target.dataset.units)
    if (!units || units === this.unitsValue) return
    const had = total(this.quantities) > 0
    this.unitsValue = units
    this.quantities = {}
    this.render()
    const label = event.target.dataset.label || "la nueva presentación"
    this.say(had ? `Cambiaste a ${label}: la selección de sabores volvió a cero. Elegí ${units} unidades.` : `${label}: elegí ${units} unidades.`)
  }

  // No se envía una caja incompleta (el botón ya está deshabilitado; esto cubre Enter y la barra fija).
  guard(event) {
    if (isComplete(this.quantities, this.unitsValue)) return
    event.preventDefault()
    const missing = remaining(this.quantities, this.unitsValue)
    this.say(`Completá la caja: ${missing === 1 ? "falta 1 unidad" : `faltan ${missing} unidades`}.`)
  }

  change(quantities) {
    this.quantities = quantities
    this.render()
  }

  idFrom(event) {
    return event.currentTarget.dataset.flavorId
  }

  render() {
    const units = this.unitsValue
    const missing = remaining(this.quantities, units)
    const complete = isComplete(this.quantities, units)

    this.flavorTargets.forEach((row) => {
      const id = row.dataset.flavorId
      const value = this.quantities[id] || 0
      row.classList.toggle("is-chosen", value > 0)
      const count = row.querySelector("[data-store-box-target='count']")
      const input = row.querySelector("[data-store-box-target='input']")
      const minus = row.querySelector("[data-store-box-target='minus']")
      const plus = row.querySelector("[data-store-box-target='plus']")
      const fillButton = row.querySelector("[data-store-box-target='fill']")
      if (count) count.textContent = value
      if (input) input.value = value
      if (minus) minus.disabled = value === 0
      if (plus) plus.disabled = missing === 0
      if (fillButton) {
        fillButton.disabled = missing === 0
        fillButton.textContent = missing === 0 ? "Listo" : (missing === units ? `Las ${units}` : `+${missing}`)
        fillButton.setAttribute("aria-label", `Completar la caja con ${row.dataset.flavorName} (${missing} más)`)
      }
    })

    if (this.hasCounterTarget) this.counterTarget.textContent = summary(this.quantities, units)
    this.unitsTargets.forEach((el) => { el.textContent = units })
    if (this.hasProgressTarget) {
      const percent = units > 0 ? Math.min(100, Math.round((total(this.quantities) / units) * 100)) : 0
      this.progressTarget.style.width = `${percent}%`
      this.progressTarget.parentElement?.setAttribute("aria-valuenow", String(total(this.quantities)))
      this.progressTarget.parentElement?.setAttribute("aria-valuemax", String(units))
    }
    this.element.classList.toggle("is-box-complete", complete)
    if (this.hasResetTarget) this.resetTarget.disabled = total(this.quantities) === 0

    this.submitButtons().forEach((button) => {
      button.disabled = !complete
      button.setAttribute("aria-disabled", String(!complete))
    })
  }

  submitButtons() {
    const own = [...this.element.querySelectorAll("button[type='submit']")]
    const external = this.element.id ? [...document.querySelectorAll(`button[form='${this.element.id}']`)] : []
    return own.concat(external)
  }

  say(message) {
    if (!this.hasNoticeTarget) return
    this.noticeTarget.textContent = message
    this.noticeTarget.hidden = false
  }
}
