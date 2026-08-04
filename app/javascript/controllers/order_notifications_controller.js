import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"

const SOUND_PREFERENCE_KEY = "hans-order-sound-enabled"
const CHIME_SRC = "/sounds/order-chime.wav"
const CHIME_GAP_MS = 300

// Aviso en tiempo real de pedidos nuevos para admin/producción: se suscribe
// a OrdersChannel, muestra un banner accesible por pedido, y reproduce dos
// campanadas (archivo .wav, volumen máximo) respetando la preferencia
// guardada en localStorage. Montado una sola vez en el layout.
export default class extends Controller {
  static targets = ["container", "template"]
  static values = { currentUrl: String }

  connect() {
    this.seenOrderIds = new Set()
    this.consumer = createConsumer()
    this.subscription = this.consumer.subscriptions.create("OrdersChannel", {
      received: (data) => this.handleReceived(data)
    })
  }

  disconnect() {
    if (this.subscription) this.subscription.unsubscribe()
    if (this.consumer) this.consumer.disconnect()
  }

  handleReceived(data) {
    if (!data || data.type !== "order_created") return
    if (this.seenOrderIds.has(data.order_id)) return
    this.seenOrderIds.add(data.order_id)

    this.showBanner(data)
    this.maybePlaySound(data.order_id)
  }

  // localStorage es sincrónico y compartido entre pestañas del mismo
  // origen: la primera pestaña en llegar acá pone el "candado" y las demás
  // lo ven de inmediato, así que como máximo una pestaña reproduce el
  // sonido por pedido. No es perfectamente atómico entre procesos, pero es
  // más que suficiente para el caso real (varias pestañas de HANS abiertas
  // en la misma computadora).
  soundAlreadyPlayedElsewhere(orderId) {
    const lockKey = `hans-order-sound-lock-${orderId}`
    if (localStorage.getItem(lockKey)) return true

    localStorage.setItem(lockKey, "1")
    setTimeout(() => localStorage.removeItem(lockKey), 15000)
    return false
  }

  showBanner(data) {
    const fragment = this.templateTarget.content.cloneNode(true)

    fragment.querySelector('[data-order-notifications-target="customerName"]').textContent = data.customer_name
    fragment.querySelector('[data-order-notifications-target="orderNumber"]').textContent = data.order_number

    const link = fragment.querySelector('[data-order-notifications-target="viewLink"]')
    link.href = data.url

    this.containerTarget.appendChild(fragment)
  }

  dismiss(event) {
    const banner = event.target.closest(".order-notification-banner")
    if (banner) banner.remove()
  }

  refresh(event) {
    if (window.Turbo) {
      window.Turbo.visit(this.currentUrlValue, { action: "replace" })
    } else {
      window.location.reload()
    }
    this.dismiss(event)
  }

  maybePlaySound(orderId) {
    if (localStorage.getItem(SOUND_PREFERENCE_KEY) === "false") return
    if (this.soundAlreadyPlayedElsewhere(orderId)) return

    this.playChime()
    setTimeout(() => this.playChime(), CHIME_GAP_MS)
  }

  // Dos instancias de Audio independientes (no una sola reiniciada) para
  // que la cola de la primera campanada pueda seguir sonando mientras
  // arranca la segunda, como una campana real de comercio golpeada dos
  // veces. Si el navegador bloquea el autoplay, falla en silencio — el
  // banner visual ya se mostró, así que el aviso no se pierde.
  playChime() {
    try {
      const audio = new Audio(CHIME_SRC)
      audio.volume = 1.0
      const playPromise = audio.play()
      if (playPromise && typeof playPromise.catch === "function") {
        playPromise.catch(() => {})
      }
    } catch (error) {
      // Restricciones de autoplay u otro problema de audio — sin sonido,
      // pero sin romper nada más.
    }
  }
}
