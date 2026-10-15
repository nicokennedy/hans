import { Controller } from "@hotwired/stimulus"

// Fila de tabla clickeable: un clic en cualquier parte de la fila navega a urlValue
// (la misma URL que su botón "Ver"). Los clics sobre enlaces, botones, formularios u
// otros controles de la fila se dejan pasar sin tocar, y seleccionar texto no navega.
// Ctrl/Cmd/Shift o el botón del medio abren en otra pestaña, como un enlace. Para
// teclado, la fila ya tiene enlaces navegables (el nombre y "Ver").
const INTERACTIVE = "a, button, input, select, textarea, label, summary, form, [role='button'], [data-row-link-ignore]"

export default class extends Controller {
  static values = { url: String }

  visit(event) {
    if (event.defaultPrevented || event.button > 1) return
    if (event.target.closest(INTERACTIVE)) return
    if (window.getSelection()?.toString()) return

    if (event.button === 1 || event.metaKey || event.ctrlKey || event.shiftKey) {
      window.open(this.urlValue, "_blank", "noopener")
    } else {
      window.Turbo.visit(this.urlValue)
    }
  }
}
