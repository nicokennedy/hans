import { Controller } from "@hotwired/stimulus"
import { formatPesos, parsePesos, suggest, summarize } from "payment_distribution"

// Formulario de pago de cuenta corriente y de aplicación de saldo a favor: propone la
// distribución automática (pedido más antiguo primero), deja editarla y muestra siempre
// Monto recibido − Monto distribuido = Saldo sin aplicar antes de confirmar. El servidor
// revalida todo; esto es solo ayuda visual.
export default class extends Controller {
  static targets = ["amount", "row", "input", "received", "applied", "credit", "pendingAfter", "errors", "submit", "autoNote"]
  static values = { fixedAmount: Number, confirmLabel: String }

  connect() {
    this.manual = false
    this.refresh({ fill: this.inputTargets.every((input) => input.value.trim() === "") })
  }

  amountChanged() {
    this.refresh({ fill: !this.manual })
  }

  allocationChanged() {
    this.manual = true
    this.refresh({ fill: false })
  }

  reset(event) {
    event?.preventDefault()
    this.manual = false
    this.refresh({ fill: true })
  }

  amountCents() {
    if (this.hasFixedAmountValue && this.fixedAmountValue > 0) return this.fixedAmountValue
    if (!this.hasAmountTarget) return 0

    const cents = parsePesos(this.amountTarget.value)
    return cents ?? 0
  }

  orders() {
    return this.rowTargets.map((row) => ({ id: row.dataset.orderId, balance: Number(row.dataset.balance) }))
  }

  refresh({ fill }) {
    const amountCents = this.amountCents()

    if (fill) {
      const { allocations } = suggest(this.orders(), amountCents)
      this.inputTargets.forEach((input) => {
        const cents = allocations[input.dataset.orderId]
        input.value = cents ? formatPesos(cents) : ""
      })
      if (this.hasAutoNoteTarget) this.autoNoteTarget.hidden = false
    } else if (this.hasAutoNoteTarget) {
      this.autoNoteTarget.hidden = !(this.manual === false)
    }

    const rows = this.inputTargets.map((input) => {
      const text = input.value.trim()
      const cents = text === "" ? 0 : parsePesos(text)
      const row = this.rowTargets.find((r) => r.dataset.orderId === input.dataset.orderId)
      return { id: input.dataset.orderId, label: row?.dataset.orderNumber, balance: Number(row?.dataset.balance ?? 0), cents, invalid: cents === null }
    })

    const pendingTotal = this.orders().reduce((sum, order) => sum + order.balance, 0)
    const summary = summarize({ amountCents, rows, pendingTotal })
    this.summary = summary

    this.receivedTarget.textContent = `$${formatPesos(summary.received)}`
    this.appliedTarget.textContent = `$${formatPesos(summary.applied)}`
    this.creditTarget.textContent = `$${formatPesos(summary.unapplied)}`
    this.creditTarget.classList.toggle("text-danger", summary.unapplied < 0)
    this.pendingAfterTarget.textContent = `$${formatPesos(summary.pendingAfter)}`
    this.errorsTarget.innerHTML = ""
    summary.errors.forEach((message) => {
      const item = document.createElement("div")
      item.textContent = message
      this.errorsTarget.appendChild(item)
    })
    this.errorsTarget.hidden = summary.errors.length === 0

    const canSubmit = summary.valid && (this.hasFixedAmountValue ? summary.applied > 0 : summary.received > 0)
    this.submitTarget.disabled = !canSubmit
  }

  confirm(event) {
    this.refresh({ fill: false })
    const s = this.summary
    if (!s?.valid) {
      event.preventDefault()
      return
    }

    const message = `${this.confirmLabelValue}\n\nMonto recibido: $${formatPesos(s.received)}\nAplicado a pedidos: $${formatPesos(s.applied)}\nSaldo a favor: $${formatPesos(s.credit)}\nSaldo pendiente posterior: $${formatPesos(s.pendingAfter)}\n\n¿Confirmar?`
    if (!window.confirm(message)) event.preventDefault()
  }
}
