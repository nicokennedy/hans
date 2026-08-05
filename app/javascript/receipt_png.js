// Módulo reutilizable para convertir el remito (o cualquier bloque del DOM)
// en una imagen PNG. Separado a propósito de cualquier Stimulus controller
// puntual: los próximos sprints (4B "Compartir remito" vía el share sheet
// nativo, y 4C "pantalla de remitos" en lote) van a llamar a
// `captureElementAsPng` de nuevo en vez de reimplementar la captura.
//
// html2canvas se importa de forma dinámica (no en el <head> de cada
// página) para no cargarle ~220KB a todas las pantallas de pedidos que
// nunca usan el botón de descarga.

// En iOS/iPadOS, la descarga vía <a download> no es confiable (Safari
// suele navegar a la imagen en vez de guardarla). Es una limitación
// conocida del motor, no algo detectable por feature-testing — por eso
// acá sí corresponde mirar la plataforma, a diferencia de la detección de
// soporte de Web Push (que es feature-detection puro).
export function isAppleTouchDevice() {
  return /iPad|iPhone|iPod/.test(navigator.userAgent) ||
    (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1)
}

// Debe llamarse de forma SINCRÓNICA, antes de cualquier `await` (incluida
// la captura con html2canvas) — Safari e iOS solo permiten `window.open`
// sin bloquearlo como popup cuando ocurre como resultado directo e
// inmediato del gesto de la persona (el toque en el botón). Si se llama
// después de esperar la captura, el navegador ya no lo considera un gesto
// directo y lo bloquea en silencio, que es exactamente lo que pasaba
// antes de este cambio.
export function openPlaceholderWindow() {
  return window.open("", "_blank")
}

// Resolución alta para que se vea nítido incluso reenviado por WhatsApp
// (que recomprime la imagen). Nunca menos de 2x.
function captureScale() {
  return Math.max(window.devicePixelRatio || 1, 2)
}

export async function captureElementAsPng(element) {
  const { default: html2canvas } = await import("html2canvas")

  const canvas = await html2canvas(element, {
    backgroundColor: "#ffffff",
    scale: captureScale(),
    useCORS: true
  })

  return new Promise((resolve, reject) => {
    canvas.toBlob((blob) => {
      if (blob) {
        resolve(blob)
      } else {
        reject(new Error("No se pudo generar la imagen."))
      }
    }, "image/png")
  })
}

// Descarga el blob directamente en la mayoría de los navegadores. En
// dispositivos Apple táctiles, muestra la imagen en una pestaña nueva y
// visible para que la persona la guarde o comparta manualmente (mantener
// presionado / usar el botón de compartir de Safari), como pide el sprint
// cuando la descarga directa no es confiable.
//
// `preOpenedWindow`, si se pasa, tiene que venir de openPlaceholderWindow()
// llamado sincrónicamente en el handler del click — así se muestra la
// imagen sin que el navegador lo trate como un popup bloqueado.
//
// Devuelve un objeto { method } para que quien llama pueda mostrar un
// mensaje claro:
//   "download"  -> se disparó la descarga directa
//   "new_tab"   -> la imagen se abrió en una pestaña ya visible
//   "blocked"   -> el navegador bloqueó la apertura de la pestaña
export function deliverPng(blob, filename, { preOpenedWindow } = {}) {
  const url = URL.createObjectURL(blob)

  if (isAppleTouchDevice()) {
    const target = preOpenedWindow && !preOpenedWindow.closed
      ? preOpenedWindow
      : window.open(url, "_blank")

    if (!target || target.closed) {
      URL.revokeObjectURL(url)
      return { method: "blocked" }
    }

    if (target === preOpenedWindow) target.location.href = url
    setTimeout(() => URL.revokeObjectURL(url), 60000)
    return { method: "new_tab" }
  }

  const link = document.createElement("a")
  link.href = url
  link.download = filename
  document.body.appendChild(link)
  link.click()
  link.remove()
  setTimeout(() => URL.revokeObjectURL(url), 5000)
  return { method: "download" }
}
