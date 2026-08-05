import { Controller } from "@hotwired/stimulus"
import { captureElementAsPng, deliverPng } from "receipt_png"

// Botón "Descargar PNG": delega toda la captura/entrega al módulo
// reutilizable receipt_png.js — este controller solo conoce el elemento a
// capturar (por id, nunca por posición en el DOM) y el estado del botón
// mientras se genera la imagen.
export default class extends Controller {
  static values = { targetId: String, filename: String }

  async download(event) {
    event.preventDefault()

    const element = document.getElementById(this.targetIdValue)
    if (!element) return

    const button = event.currentTarget
    const originalLabel = button.textContent
    button.disabled = true
    button.textContent = "Generando…"

    try {
      const blob = await captureElementAsPng(element)
      deliverPng(blob, this.filenameValue)
    } catch (error) {
      console.error("No se pudo generar el PNG del remito:", error)
      window.alert("No se pudo generar la imagen del remito. Probá de nuevo.")
    } finally {
      button.disabled = false
      button.textContent = originalLabel
    }
  }
}
