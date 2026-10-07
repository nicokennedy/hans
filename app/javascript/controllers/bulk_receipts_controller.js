import { Controller } from "@hotwired/stimulus"
import {
  canvasToBlob,
  captureElementAsCanvas,
  deliverBlob,
  isAppleTouchDevice,
  openPlaceholderWindow
} from "receipt_png"
import { PDF_RECEIPT_WIDTH_PX, PRINT_DEFAULTS, layoutReceipts } from "receipt_layout"
import { buildPdf } from "pdf_writer"

// Botón "Generar PDF" de la impresión masiva de remitos. Cada remito del día
// ya viene renderizado (oculto) por el servidor con el MISMO partial que el
// remito individual (orders/_receipt). Acá solo se capturan con la misma
// captura que el PNG (en su variante compacta de impresión), se acomodan en
// hojas A4 horizontales (receipt_layout.js: las 2 copias de cada pedido lado a
// lado, con la altura real de cada uno) y se escribe el PDF (pdf_writer.js).
const CAPTURE_SCALE = 3 // 3 x 4 px/mm = 12 px/mm ≈ 305 dpi sobre el papel
const JPEG_QUALITY = 0.95

export default class extends Controller {
  static targets = ["receipt", "button", "status"]
  static values = { filename: String, copies: { type: Number, default: PRINT_DEFAULTS.copies } }

  async generate(event) {
    event.preventDefault()
    if (this.receiptTargets.length === 0) return

    // Igual que el PNG individual: en Apple táctil la pestaña se reserva
    // acá, dentro del gesto del click, antes de cualquier await.
    let preOpenedWindow = null
    if (isAppleTouchDevice()) {
      preOpenedWindow = openPlaceholderWindow()

      if (!preOpenedWindow) {
        this.showStatus("El navegador bloqueó la apertura de una nueva pestaña. Permití las ventanas emergentes para HANS e intentá de nuevo.", "error")
        return
      }
    }

    const originalLabel = this.buttonTarget.textContent
    this.buttonTarget.disabled = true
    this.showStatus("", null)

    try {
      const images = await this.captureAll()
      this.buttonTarget.textContent = "Armando PDF…"

      const { pages } = layoutReceipts(images, { copies: this.copiesValue })
      const bytes = buildPdf({
        pageWidth: PRINT_DEFAULTS.pageWidth,
        pageHeight: PRINT_DEFAULTS.pageHeight,
        images: images.map(({ data, width, height }) => ({ data, width, height })),
        pages: pages.map((placements) => placements.map(({ item, x, y, width, height }) => (
          { imageIndex: item.index, x, y, width, height }
        ))),
        title: this.filenameValue.replace(/\.pdf$/i, "")
      })

      const result = deliverBlob(new Blob([bytes], { type: "application/pdf" }), this.filenameValue, { preOpenedWindow })
      this.reportResult(result, images.length, pages.length)
    } catch (error) {
      console.error("No se pudo generar el PDF de remitos:", error)
      if (preOpenedWindow && !preOpenedWindow.closed) preOpenedWindow.close()
      this.showStatus("No se pudo generar el PDF de remitos. Probá de nuevo.", "error")
    } finally {
      this.buttonTarget.disabled = false
      this.buttonTarget.textContent = originalLabel
    }
  }

  // Secuencial a propósito: capturar de a uno mantiene bajo el uso de
  // memoria (importante en celulares/tablets).
  async captureAll() {
    const images = []
    const total = this.receiptTargets.length

    for (const [index, element] of this.receiptTargets.entries()) {
      this.buttonTarget.textContent = `Generando ${index + 1} de ${total}…`

      const canvas = await captureElementAsCanvas(element, { width: PDF_RECEIPT_WIDTH_PX, scale: CAPTURE_SCALE, variant: "print" })
      const blob = await canvasToBlob(canvas, "image/jpeg", JPEG_QUALITY)
      images.push({
        index,
        data: new Uint8Array(await blob.arrayBuffer()),
        width: canvas.width,
        height: canvas.height
      })

      canvas.width = 0 // libera la memoria del canvas
      canvas.height = 0
    }

    return images
  }

  reportResult(result, receiptCount, pageCount) {
    const summary = `${receiptCount} remitos x ${this.copiesValue} copias en ${pageCount} ${pageCount === 1 ? "hoja" : "hojas"} A4 horizontales.`

    if (result.method === "new_tab") {
      this.showStatus(`${summary} El PDF se abrió en una nueva pestaña: guardalo o imprimilo desde ahí.`, "success")
    } else if (result.method === "blocked") {
      this.showStatus("El navegador bloqueó la apertura del PDF. Permití las ventanas emergentes para HANS e intentá de nuevo.", "error")
    } else {
      this.showStatus(`${summary} El PDF se descargó correctamente.`, "success")
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
