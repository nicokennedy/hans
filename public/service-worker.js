// Service worker de HANS — pensado ÚNICAMENTE para Web Push, no para modo
// offline. No implementa `fetch`, así que nunca intercepta pedidos de red:
// Turbo, el asset pipeline, el login y toda la navegación normal funcionan
// exactamente igual que sin este archivo.

self.addEventListener("install", (event) => {
  self.skipWaiting()
})

self.addEventListener("activate", (event) => {
  event.waitUntil(self.clients.claim())
})

self.addEventListener("push", (event) => {
  let data = {}

  try {
    data = event.data ? event.data.json() : {}
  } catch (e) {
    data = { title: "Nuevo pedido HANS", body: "Abrí HANS para ver el detalle." }
  }

  const title = data.title || "Nuevo pedido HANS"
  const options = {
    body: data.body || "",
    icon: "/icon-192.png",
    badge: "/icon-192.png",
    tag: data.tag || "hans-notification",
    // Datos que necesitamos al hacer click, guardados en la notificación
    // misma (el service worker no comparte memoria con la pestaña).
    data: { url: data.url || "/" },
    timestamp: data.timestamp || Date.now()
  }

  event.waitUntil(self.registration.showNotification(title, options))
})

self.addEventListener("notificationclick", (event) => {
  event.notification.close()

  const targetUrl = event.notification.data && event.notification.data.url
    ? event.notification.data.url
    : "/"

  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((windowClients) => {
      const targetAbsoluteUrl = new URL(targetUrl, self.location.origin).href

      for (const client of windowClients) {
        // Ya hay una ventana de HANS abierta: enfocarla y navegarla al
        // pedido en vez de abrir una pestaña nueva.
        if (client.url.startsWith(self.location.origin) && "focus" in client) {
          return client.focus().then(() => {
            if ("navigate" in client) return client.navigate(targetAbsoluteUrl)
          })
        }
      }

      return self.clients.openWindow(targetAbsoluteUrl)
    })
  )
})
