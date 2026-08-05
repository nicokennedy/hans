import { Controller } from "@hotwired/stimulus"
import { captureElementAsPng, deliverPng, isAppleTouchDevice, openPlaceholderWindow } from "receipt_png"

// Botón "Descargar PNG": delega toda la captura/entrega al módulo
// reutilizable receipt_png.js — este controller solo conoce el elemento a
// capturar (por id, nunca por posición en el DOM), el estado del botón
// mientras se genera la imagen, y muestra un mensaje visible del resultado
// (descarga / pestaña nueva / bloqueado), sobre todo importante en
// Safari/iPhone/iPad donde no hay una descarga de archivo tradicional.
export default class extends Controller {
  static targets = ["status"]
  static values = { targetId: String, filename: String }

  async download(event) {
    event.preventDefault()

    const element = document.getElementById(this.targetIdValue)
    if (!element) return

    const button = event.currentTarget
    const originalLabel = button.textContent

    // En Apple táctil hay que reservar la pestaña ACÁ, todavía dentro del
    // gesto de tocar el botón — si se abre recién después de esperar la
    // captura (que es asincrónica), Safari ya no lo considera un gesto
    // directo del usuario y bloquea la apertura sin avisar.
    let preOpenedWindow = null
    if (isAppleTouchDevice()) {
      preOpenedWindow = openPlaceholderWindow()

      if (!preOpenedWindow) {
        this.showStatus("El navegador bloqueó la apertura de una nueva pestaña. Permití las ventanas emergentes para HANS e intentá de nuevo.", "error")
        return
      }
    }

    button.disabled = true
    button.textContent = "Generando…"
    this.showStatus("", null)

    try {
      const blob = await captureElementAsPng(element)
      const result = deliverPng(blob, this.filenameValue, { preOpenedWindow })
      this.reportResult(result)
    } catch (error) {
      console.error("No se pudo generar el PNG del remito:", error)
      if (preOpenedWindow && !preOpenedWindow.closed) preOpenedWindow.close()
      this.showStatus("No se pudo generar la imagen del remito. Probá de nuevo.", "error")
    } finally {
      button.disabled = false
      button.textContent = originalLabel
    }
  }

  reportResult(result) {
    if (result.method === "new_tab") {
      this.showStatus("La imagen se abrió en una nueva pestaña. Mantenela presionada para guardarla o compartirla.", "success")
    } else if (result.method === "blocked") {
      this.showStatus("El navegador bloqueó la apertura de la imagen. Permití las ventanas emergentes para HANS e intentá de nuevo.", "error")
    } else {
      this.showStatus("La imagen se descargó correctamente.", "success")
    }
  }

  showStatus(message, kind) {
    if (!this.hasStatusTarget) return

    this.statusTarget.textContent = message
    this.statusTarget.classList.remove("text-success", "text-danger", "text-muted")

    if (kind === "error") {
      this.statusTarget.classList.add("text-danger")
    } else if (kind === "success") {
      this.statusTarget.classList.add("text-success")
    }
  }
}
