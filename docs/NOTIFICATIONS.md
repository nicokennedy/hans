# Notificaciones de pedidos nuevos (Action Cable + Web Push)

Este documento describe la implementación del aviso en tiempo real de
pedidos nuevos para admin y producción: notificación dentro de HANS
(Action Cable) y notificación del sistema operativo aunque HANS esté
cerrada o la pantalla bloqueada (Web Push con VAPID).

## 1. Arquitectura

```
Order#save! (create)
   └─ after_create_commit :notify_order_created
        └─ Notifications::OrderCreatedBroadcaster.call(order)
             ├─ OrdersChannel.broadcast_order_created(payload)   → Action Cable
             │    └─ sesiones admin/producción con HANS abierta
             │         ven el banner al instante (Stimulus)
             └─ PushNotificationJob.perform_later(order.id)      → ActiveJob
                  └─ vuelve a buscar el pedido, arma el payload
                     y envía Web Push a cada PushSubscription
                     elegible (admin/producción), vía la gema web-push
```

El disparo está centralizado en **un solo lugar**: un callback
`after_create_commit` en el modelo `Order`. Corre una sola vez, después de
que la fila ya está confirmada en la base — nunca antes del commit, nunca
en un `update` posterior (editar, cambiar estado, registrar un pago). Cubre
automáticamente los dos únicos puntos donde se crea un pedido hoy
(`OrdersController#create` del cliente y `Admin::OrdersController#create`)
sin duplicar lógica entre ambos.

### Por qué Action Cable con adapter Redis

`config/cable.yml` ya declaraba el adapter `redis` para producción desde
antes de este sprint — lo que faltaba era la gema (`gem "redis"`, agregada
ahora). Se mantiene Redis en producción (no `async`) porque Heroku puede
escalar a más de un dyno web, y solo un adapter con pub/sub compartido
(Redis) garantiza que un broadcast disparado en un dyno llegue a una
conexión websocket abierta en otro. Desarrollo y test siguen usando
`async`/`test` — no necesitan Redis.

### Por qué la gema `web-push`

Es la implementación Ruby estándar del protocolo Web Push con firma VAPID
(JWT + ES256), mantenida activamente, sin dependencias nativas más allá de
`jwt`/`openssl`/`base64` (todas ya presentes en cualquier app Rails). No se
evaluó Firebase Cloud Messaging: el sprint pide explícitamente preferir Web
Push estándar salvo que FCM sea imprescindible, y no lo es — VAPID cubre
Chrome, Edge, Firefox y Safari (macOS/iOS 16.4+) sin intermediarios.

### Por qué no se agregó un adapter de colas persistente

`ActiveJob` sigue usando el adapter `:async` por defecto (no había ninguno
configurado antes de este sprint). Es suficiente para este caso de uso: el
job se encola y corre casi inmediatamente después del commit, dentro del
mismo proceso. La limitación real es que un reinicio de dyno justo en ese
instante perdería el job encolado — un riesgo aceptable para una
notificación (no crítica, no financiera) en una app de bajo volumen. Si en
el futuro esto se vuelve un problema, `solid_queue` (gema oficial de Rails,
sin Redis) es la migración natural.

## 2. Flujo Action Cable

* Canal: `OrdersChannel` (`app/channels/orders_channel.rb`). Un solo stream
  compartido (`"orders_channel"`) — no hay datos por-pedido que filtrar por
  destinatario, porque admin y producción ven la misma pantalla de pedido.
* Autorización: `ApplicationCable::Connection#connect` reutiliza la sesión
  Devise/Warden existente (`env["warden"].user`) — la misma que protege
  cualquier otro controller, sin sistema paralelo. `OrdersChannel#subscribed`
  llama a `current_user&.admin_or_production?` (el mismo método ya usado en
  `ApplicationController`) y rechaza (`reject`) a cualquier otro caso:
  clientes, o conexiones sin usuario identificado.
* Payload transmitido (`type: "order_created"`): `order_id`, `order_number`,
  `customer_name`, `created_at`, `url` (path relativo a
  `/admin/orders/:id`, válido tanto para admin como para producción). Nunca
  incluye costos, márgenes, ni datos de pago.

## 3. Flujo Web Push

1. La persona entra a **Notificaciones** (`/admin/push_settings`) y toca
   **"Activar notificaciones"** — el permiso del navegador solo se pide ahí,
   nunca automáticamente.
2. El navegador genera una `PushSubscription` (endpoint + claves
   `p256dh`/`auth`) y el JS la registra en el servidor
   (`POST /admin/push_subscriptions`), guardada como fila de
   `PushSubscription` (ver modelo abajo).
3. Al crearse un pedido, `PushNotificationJob` vuelve a buscar el pedido por
   id (nunca recibe el objeto serializado), arma un payload mínimo, y llama
   a `WebPush.payload_send` para cada suscripción elegible.
4. El *service worker* (`public/service-worker.js`) recibe el evento
   `push`, muestra la notificación del sistema, y al tocarla abre (o
   enfoca) HANS directamente en el pedido.

### Modelo `PushSubscription`

Una fila por dispositivo/navegador. Columnas: `user_id` (obligatorio),
`endpoint` (único), `p256dh_key`, `auth_key`, `device_label` (opcional,
solo para mostrarle a la persona qué dispositivo es — "iPhone", "Android",
etc., nunca user-agent completo ni IP), timestamps.

* **Alta idempotente**: registrar el mismo `endpoint` de nuevo actualiza la
  fila existente en vez de duplicarla.
* **Un dispositivo puede cambiar de dueño**: si el mismo `endpoint` ya
  pertenecía a otro usuario (dispositivo compartido), un alta explícita
  reasigna la fila al usuario que la está pidiendo ahora. Esto es
  intencional — cerrar sesión nunca hace que alguien "herede" en silencio
  una suscripción ajena (nada se reasigna sin una acción explícita de la
  persona), pero si esa persona activa notificaciones explícitamente en un
  dispositivo ya usado por otra, la suscripción pasa a ser suya.
* **Baja**: "Desactivar notificaciones" borra la fila y llama a
  `PushSubscription.unsubscribe()` en el navegador.
* **Suscripciones vencidas**: si el servicio push devuelve 410 (Gone) o 404
  (Not Found) al enviar, se borra la fila automáticamente. Errores
  transitorios (5xx, 429, error de configuración VAPID) **no** borran nada.

## 4. Endpoints

Todos bajo `namespace :admin`, protegidos por
`require_admin_or_production!` (el mismo helper centralizado que ya usa el
resto del admin):

| Método | Ruta | Acción |
|---|---|---|
| GET | `/admin/push_settings` | Pantalla de configuración |
| POST | `/admin/push_subscriptions` | Alta/actualización (idempotente) |
| DELETE | `/admin/push_subscriptions/:id` | Baja (solo la propia) |
| POST | `/admin/push_subscriptions/:id/test` | Notificación de prueba (solo la propia) |

`user_id` nunca llega por parámetro — siempre se toma de `current_user`, así
que no hay mass assignment posible hacia otro usuario. `destroy`/`test`
buscan la suscripción dentro de `current_user.push_subscriptions`, así que
un 404 es la única respuesta posible para el id de otra persona.

## 5. Variables de entorno (VAPID)

* `WEB_PUSH_VAPID_PUBLIC_KEY` — clave pública (puede llegar al navegador).
* `WEB_PUSH_VAPID_PRIVATE_KEY` — clave privada (**nunca** sale del backend:
  no se renderiza en ninguna vista, no se loguea, no llega al JS).
* `WEB_PUSH_VAPID_SUBJECT` — contacto obligatorio del protocolo VAPID,
  formato `mailto:alguien@hans.example.com` o una URL `https://`.

Si falta cualquiera de las tres, `Notifications::WebPushVapid.configured?`
devuelve `false`: la pantalla de configuración muestra el estado "Error de
configuración del servidor" y `PushNotificationJob` no intenta enviar nada
(loguea un error claro y corta, sin romper la creación del pedido).

### Generar las claves

```bash
bin/rails runner "key = WebPush.generate_key; puts \"PUBLIC: #{key.public_key}\"; puts \"PRIVATE: #{key.private_key}\""
```

### Configurar en local

```bash
export WEB_PUSH_VAPID_PUBLIC_KEY="..."
export WEB_PUSH_VAPID_PRIVATE_KEY="..."
export WEB_PUSH_VAPID_SUBJECT="mailto:vos@hans.example.com"
```

(o agregalas a tu `.env` local si usás alguna gema de carga de `.env`).

### Configurar en Heroku (comandos sugeridos, no ejecutados)

```bash
heroku config:set WEB_PUSH_VAPID_PUBLIC_KEY="..." --app hans
heroku config:set WEB_PUSH_VAPID_PRIVATE_KEY="..." --app hans
heroku config:set WEB_PUSH_VAPID_SUBJECT="mailto:vos@hans.example.com" --app hans
```

También hace falta un Redis para Action Cable en producción (ver más
abajo) — el add-on más simple:

```bash
heroku addons:create heroku-redis:mini --app hans
```

Heroku Redis configura automáticamente la variable `REDIS_URL`, que
`config/cable.yml` ya lee.

## 6. Cómo activar notificaciones por dispositivo

**Chrome/Edge de escritorio, Chrome en Android**: entrar a
`/admin/push_settings` → "Activar notificaciones" → aceptar el permiso del
navegador. Listo.

**iPhone/iPad (Safari)**: Apple solo permite Web Push si el sitio está
agregado como aplicación a la pantalla de inicio. Pasos exactos (los mismos
que muestra la pantalla de configuración cuando detecta un dispositivo
Apple sin instalar):

1. Abrir HANS en Safari (no funciona desde Chrome ni otro navegador en iOS).
2. Tocar el botón "Compartir" (el cuadrado con una flecha hacia arriba).
3. Elegir "Agregar a pantalla de inicio".
4. Abrir HANS desde el nuevo ícono en la pantalla de inicio.
5. Ir a "Notificaciones" y tocar "Activar notificaciones".
6. Aceptar el permiso que pida el sistema.

## 7. Cómo probarlas

1. Con dos sesiones (por ejemplo, dos navegadores o uno normal y uno de
   incógnito) iniciadas como admin y como producción, dejar ambas pantallas
   abiertas en cualquier vista de admin/producción.
2. Desde una tercera sesión de cliente, crear un pedido.
3. Ambas sesiones admin/producción deberían mostrar el banner "Nuevo pedido
   recibido" casi al instante, con un sonido corto (si el navegador lo
   permite y no está desactivado en las preferencias).
4. Tocar "Ver pedido" en el banner debe abrir el detalle correcto.
5. Para probar Web Push específicamente: activar notificaciones en
   `/admin/push_settings`, usar "Enviar notificación de prueba" (llega solo
   a ese dispositivo), y confirmar que aparece como notificación del
   sistema. Después, cerrar HANS por completo (o bloquear la pantalla en
   mobile) y crear un pedido real desde otra sesión — la notificación debe
   llegar igual.

## 8. Cómo revocar una suscripción

Desde el propio dispositivo: `/admin/push_settings` → "Desactivar
notificaciones". Borra la fila en la base y cancela la suscripción del
navegador.

Si el dispositivo ya no está disponible (perdido, robado, etc.), un
administrador con acceso a la consola puede borrarla manualmente:

```bash
bin/rails runner "PushSubscription.where(user_id: U_ID).destroy_all"
```

## 9. Troubleshooting

| Síntoma | Causa probable |
|---|---|
| El banner nunca aparece dentro de HANS | Revisar la consola del navegador — `@rails/actioncable` no pudo conectar. En producción, confirmar que el addon de Redis esté activo y `REDIS_URL` configurada. |
| "Error de configuración del servidor" en `/admin/push_settings` | Faltan una o más variables `WEB_PUSH_VAPID_*`. |
| La notificación de prueba nunca llega | Revisar los logs del job (`Rails.logger`) — busca líneas `[WebPushSender]`. Un error 401/403 casi siempre es una clave VAPID incorrecta. |
| En iPhone/iPad nunca aparece la opción de activar | HANS no está agregada a la pantalla de inicio — ver sección 6. |
| Las notificaciones dejaron de llegar a un dispositivo puntual | Es probable que el navegador haya expirado la suscripción (común tras mucho tiempo sin abrir la app) — se borra sola la próxima vez que se intenta enviar (410/404) y hay que volver a activarla desde ese dispositivo. |

## 10. Limitaciones conocidas de navegadores

* **Safari en iOS/iPadOS**: requiere estar agregada a la pantalla de inicio
  (no funciona en una pestaña normal de Safari, ni en Chrome/Firefox sobre
  iOS, que en iOS son todos WebKit por debajo y comparten esta limitación).
  Necesita iOS/iPadOS 16.4 o superior.
* **Safari en macOS**: soporta Web Push desde Safari 16, sin necesidad de
  instalar nada como app — funciona directo desde el navegador.
* **Firefox**: soporta Web Push estándar; no se probó exhaustivamente en
  este sprint pero la implementación no depende de nada específico de
  Chrome.
* **Modo incógnito/privado**: en la mayoría de los navegadores, las
  suscripciones push no persisten entre sesiones de incógnito.
* **Sin conexión**: si el dispositivo está sin internet en el momento del
  envío, el servicio push del sistema operativo (FCM, APNs vía web push,
  etc.) reintenta por su cuenta durante el tiempo de vida configurado
  (`ttl`, hoy 1 hora) — no es algo que HANS controle directamente.
* **Sonido dentro de HANS**: los navegadores bloquean audio que no se
  origine en una interacción del usuario. Si el navegador bloquea el sonido
  del banner, el aviso visual sigue funcionando igual — es el
  comportamiento esperado, no un error.
