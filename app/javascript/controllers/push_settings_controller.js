import { Controller } from "@hotwired/stimulus"

const SOUND_PREFERENCE_KEY = "hans-order-sound-enabled"

const STATE_NAMES = [
  "stateChecking",
  "stateUnsupported",
  "stateNeedsInstall",
  "statePermissionDenied",
  "stateServerError",
  "stateReadyToEnable",
  "stateEnabled",
  "stateError"
]

// Pantalla de "Notificaciones de pedidos": detección de capacidades reales
// (nunca por nombre de navegador), pedido de permiso solo ante un click
// explícito, alta/baja de la suscripción Web Push, y notificación de
// prueba limitada al dispositivo actual.
export default class extends Controller {
  static targets = [ ...STATE_NAMES, "errorMessage", "enableButton", "testButton", "testResult", "soundToggle" ]
  static values = {
    vapidPublicKey: String,
    serverConfigured: Boolean,
    createUrl: String,
    destroyUrlTemplate: String,
    testUrlTemplate: String
  }

  connect() {
    this.subscriptionId = null
    this.soundToggleTarget.checked = localStorage.getItem(SOUND_PREFERENCE_KEY) !== "false"
    this.renderState()
  }

  toggleSound() {
    localStorage.setItem(SOUND_PREFERENCE_KEY, this.soundToggleTarget.checked ? "true" : "false")
  }

  isSupported() {
    return "serviceWorker" in navigator && "PushManager" in window && "Notification" in window
  }

  isStandalone() {
    return window.matchMedia("(display-mode: standalone)").matches || navigator.standalone === true
  }

  // Solo para elegir QUÉ instrucciones mostrar — nunca para asumir soporte
  // o falta de soporte. iOS/iPadOS no expone una forma de feature-detectar
  // "todavía no está agregado a la pantalla de inicio", así que esto es lo
  // más cercano posible sin depender de un simple "if browser is Chrome".
  isAppleTouchDevice() {
    return /iPad|iPhone|iPod/.test(navigator.userAgent) ||
      (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1)
  }

  async renderState() {
    this.hideAllStates()

    if (!this.isSupported()) {
      if (this.isAppleTouchDevice() && !this.isStandalone()) {
        this.showState(this.stateNeedsInstallTarget)
      } else {
        this.showState(this.stateUnsupportedTarget)
      }
      return
    }

    if (!this.serverConfiguredValue) {
      this.showState(this.stateServerErrorTarget)
      return
    }

    if (Notification.permission === "denied") {
      this.showState(this.statePermissionDeniedTarget)
      return
    }

    if (Notification.permission === "granted") {
      const registration = await navigator.serviceWorker.ready
      const existingSubscription = await registration.pushManager.getSubscription()

      if (existingSubscription) {
        // Re-registra (upsert idempotente) para asegurarnos de tener el id
        // correcto y que la suscripción quede a nombre del usuario actual
        // — importante si el dispositivo cambió de persona desde la
        // última vez.
        await this.registerSubscription(existingSubscription)
        this.showState(this.stateEnabledTarget)
        return
      }
    }

    this.showState(this.stateReadyToEnableTarget)
  }

  hideAllStates() {
    STATE_NAMES.forEach((name) => {
      const target = this[`${name}Target`]
      if (target) target.classList.add("d-none")
    })
  }

  showState(element) {
    element.classList.remove("d-none")
  }

  // El permiso solo se pide acá, dentro de un handler de click real — nunca
  // automáticamente al cargar la página.
  async enable(event) {
    event.preventDefault()
    this.enableButtonTarget.disabled = true

    try {
      const permission = await Notification.requestPermission()

      if (permission !== "granted") {
        await this.renderState()
        return
      }

      const registration = await navigator.serviceWorker.ready
      const subscription = await registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: this.urlBase64ToUint8Array(this.vapidPublicKeyValue)
      })

      await this.registerSubscription(subscription)
      await this.renderState()
    } catch (error) {
      this.showError("No se pudo activar las notificaciones en este dispositivo.")
    } finally {
      this.enableButtonTarget.disabled = false
    }
  }

  async disable(event) {
    event.preventDefault()

    try {
      const registration = await navigator.serviceWorker.ready
      const subscription = await registration.pushManager.getSubscription()

      if (subscription) {
        if (this.subscriptionId) await this.unregisterSubscription(this.subscriptionId)
        await subscription.unsubscribe()
      }

      this.subscriptionId = null
      await this.renderState()
    } catch (error) {
      this.showError("No se pudo desactivar las notificaciones en este dispositivo.")
    }
  }

  async sendTest(event) {
    event.preventDefault()
    if (!this.subscriptionId) return

    this.testButtonTarget.disabled = true
    this.testResultTarget.textContent = "Enviando…"

    try {
      const url = this.testUrlTemplateValue.replace(":id", this.subscriptionId)
      const response = await fetch(url, {
        method: "POST",
        headers: { "X-CSRF-Token": this.csrfToken() }
      })

      this.testResultTarget.textContent = response.ok
        ? "Prueba enviada. Debería llegar en unos segundos, solo a este dispositivo."
        : "No se pudo enviar la prueba."
    } catch (error) {
      this.testResultTarget.textContent = "No se pudo enviar la prueba."
    } finally {
      this.testButtonTarget.disabled = false
    }
  }

  async registerSubscription(subscription) {
    const json = subscription.toJSON()

    const response = await fetch(this.createUrlValue, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": this.csrfToken()
      },
      body: JSON.stringify({
        subscription: {
          endpoint: json.endpoint,
          keys: json.keys,
          device_label: this.guessDeviceLabel()
        }
      })
    })

    if (response.ok) {
      const data = await response.json()
      this.subscriptionId = data.id
    }
  }

  async unregisterSubscription(id) {
    const url = this.destroyUrlTemplateValue.replace(":id", id)
    await fetch(url, {
      method: "DELETE",
      headers: { "X-CSRF-Token": this.csrfToken() }
    })
  }

  guessDeviceLabel() {
    const ua = navigator.userAgent
    if (/iPad/.test(ua)) return "iPad"
    if (/iPhone/.test(ua)) return "iPhone"
    if (/Android/.test(ua)) return "Android"
    return "Navegador de escritorio"
  }

  csrfToken() {
    const meta = document.querySelector('meta[name="csrf-token"]')
    return meta ? meta.content : ""
  }

  showError(message) {
    this.hideAllStates()
    this.errorMessageTarget.textContent = message
    this.showState(this.stateErrorTarget)
  }

  urlBase64ToUint8Array(base64String) {
    const padding = "=".repeat((4 - (base64String.length % 4)) % 4)
    const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/")
    const rawData = window.atob(base64)
    const outputArray = new Uint8Array(rawData.length)

    for (let i = 0; i < rawData.length; i++) {
      outputArray[i] = rawData.charCodeAt(i)
    }

    return outputArray
  }
}
