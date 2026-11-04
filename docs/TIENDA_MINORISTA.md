# Tienda online minorista — estado y decisiones

## Etapas

| Etapa | Estado |
|---|---|
| 0. Suite de tests confiable | Hecha (ver `docs/KNOWN_TEST_FAILURES.md`) |
| 1. Confirmación de pedidos minoristas | Hecha: origen manual/tienda, pendiente → confirmado / rechazado, solo los confirmados cuentan para producción, stock y el resumen financiero |
| 2. Catálogo minorista, precios y fotos | Hecha: administrador en Tienda Minorista → Productos / Categorías. Fotos en Cloudflare R2 (conectado y habilitado en producción) |
| 3. Reglas de retiro y delivery | Hecha: Tienda Minorista → Entregas (ver abajo) |
| 4. Tienda pública, carrito, checkout y WhatsApp | Hecha, **cerrada al público** hasta que se publique desde Tienda Minorista → Tienda online (ver abajo) |
| 5. Opcionales (stock, pago online, automatizaciones) | Pendiente |

## Base que deja la Etapa 1 para la tienda

- Un pedido de la tienda se crea con `Retail::SaveOrder.call(..., source: "store", request_token: ...)`:
  nace "Pendiente de confirmación" y no suma a producción, stock ni al resumen hasta que el equipo
  lo confirma (`Retail::ChangeConfirmation`). Rechazar exige motivo y es definitivo.
- `request_token` (único) hace idempotente el checkout: el mismo token devuelve el pedido ya creado.
- `public_token` (32 caracteres, único) es el identificador de la página pública "Pedido recibido"
  (`/tienda/pedido/<token>`): nunca se expone el id.
- `RetailOrder.committed` es la única regla de "pedido que cuenta".

## Etapa 2 — Catálogo minorista

Administrador en **Tienda Minorista** (menú lateral, solo admin): `/admin/tienda-minorista`.

- **Categorías** (`RetailCategory`): nombre único, activa/inactiva, orden (↑/↓), cantidad de
  productos. Una categoría con productos no se borra (la base también lo impide): se desactiva.
- **Productos** (`RetailProduct`): nombre, descripción, precio minorista propio (centavos, ≥ 0),
  categoría, activo, destacado, orden, código interno único (se genera del nombre si no se
  escribe) y vínculo opcional con un producto mayorista (`product_id`, solo se guarda: no cambia
  el producto mayorista, su precio ni su stock; si ese producto se borra, el vínculo se limpia).
  Buscar, filtrar por categoría y estado (activos, inactivos, listos para publicar, sin foto
  principal), ordenar, duplicar (copia inactiva y sin fotos) y eliminar (solo inactivos).
- **Listo para publicar** = activo + categoría activa + foto principal. Un producto se puede guardar
  sin fotos mientras se prepara el catálogo.
- **Fotos** (`RetailProductPhoto` + Active Storage): varias por producto, una principal (la de las
  tarjetas del catálogo; las demás van a la galería del detalle, en orden ←/→). Subida múltiple,
  reemplazo y borrado individual; borrar la última foto pide confirmación; si se borra la principal,
  pasa a serlo la siguiente. Se aceptan JPEG, PNG y WebP de hasta 5 MB, validados por su contenido
  (los primeros bytes), y no se repite una imagen en el mismo producto. `RetailCatalog::PhotoUpload`
  y `RetailCatalog::PhotoArrangement`.
- **Versiones optimizadas** (WebP, generadas la primera vez que se piden con libvips, que trae
  Heroku-24): `thumb` 160×160 (administrador), `card` 600×600 (tarjetas; nítida en celulares),
  `detail` hasta 1200 px (galería). Nunca se sirve el original en el catálogo.
  En una Mac de desarrollo hace falta `brew install vips` para ver las miniaturas.

## Etapa 3 — Retiro y envío

Administrador en **Tienda Minorista → Entregas** (`/admin/tienda-minorista/entregas`, solo admin).
Todo es independiente del reparto mayorista: `DeliverySetting`, `BlockedDate`, cortes y días
mayoristas no se usan ni se modifican.

### Modalidades (nombres que ve el cliente)

| Modalidad (`delivery_kind`) | Nombre | Costo | Días y franja inicial |
|---|---|---|---|
| `pickup` | **Retiro por zona Plaza del Agua** | $0 — Gratis | Lunes a viernes 14:00 a 17:00 hs · sábados 11:00 a 13:00 hs |
| `delivery` | **Envío a domicilio** | Según la zona | Lunes a sábado 8:30 a 13:00 hs (franja de entrega, no turno exacto) |

Domingos sin servicio. La dirección del punto de retiro **no está definida**: se carga en
"Reglas generales" (mientras esté vacía, el cliente ve solo el nombre de la modalidad).

### Zonas de envío (iniciales)

| Zona | Cobertura (orientativa) | Costo |
|---|---|---|
| Zona 1 | Costa, Independencia, Colón, Vértiz | $5.000 |
| Zona 2 | Centro, zona Facultad | $6.000 |
| Zona 3 | Constitución, barrios privados, Champagnat hasta Allio | $7.000 |

El cliente elige la zona a mano (no hay geolocalización ni validación de direcciones). El costo
sale siempre de la zona, en el servidor. Cada pedido guarda la zona (`delivery_zone_id`), su
nombre (`delivery_zone_name`), la franja (`delivery_window_label`) y el costo aplicado
(`shipping_cents`, la columna que ya existía): cambiar un precio o renombrar una zona no modifica
pedidos ya creados. Una zona usada por pedidos no se borra: se desactiva.

### Anticipación mínima

**Días calendario, no horas**: primera fecha = fecha de hoy en Argentina
(`America/Argentina/Buenos_Aires`) + anticipación (inicial: 2). Después se aplican los días
habilitados y las fechas sin servicio. Lunes (a cualquier hora) → miércoles; viernes o sábado →
lunes. Se pueden elegir fechas hasta 90 días hacia adelante (`RetailFulfillment::HORIZON_DAYS`).

### Qué se configura desde el administrador

- Anticipación mínima (0 a 30 días) e indicaciones del punto de retiro.
- Días habilitados y franja (desde/hasta) de cada modalidad, por día de la semana.
- Zonas: nombre, cobertura, costo, activa, orden.
- Fechas sin servicio: solo retiro, solo envío o ambas, con motivo opcional (lo ve el cliente).
- Simulador "Qué vería un cliente hoy": próximas fechas por modalidad y cálculo de envío y total
  con la misma validación que usará el checkout.

### Para la Etapa 4 (tienda pública y checkout)

- `RetailFulfillment::Options.call` → Hash listo para JSON con modalidades, costo, franjas por día,
  fechas habilitadas (ya filtradas) y zonas activas con su precio, para armar el paso de entrega.
- `RetailFulfillment::Quote.call(service:, date:, zone_id:, address:, subtotal_cents:)` → valida y
  calcula envío y total (para mostrar el resumen antes de confirmar).
- `Retail::PlaceStoreOrder.call(attributes:, cart:, request_token:)` → **la única entrada para crear
  pedidos de la tienda**: vuelve a validar fecha, zona y dirección en el servidor, ignora cualquier
  importe que mande el cliente, guarda zona/franja/costo y crea el pedido "Pendiente de
  confirmación" (idempotente por `request_token`). Desde la Etapa 4 recibe el carrito (ids y
  cantidades) y arma los ítems con el precio del catálogo minorista.
- `Retail::SaveOrder` sigue siendo el camino del equipo: los pedidos manuales pueden tener cualquier
  fecha y otro costo de envío (pedidos especiales, solo admin). En el formulario hay una "Zona de
  envío" opcional que completa el envío con el precio de la zona.

### Pedidos existentes

La migración solo agrega columnas opcionales: los pedidos anteriores quedan sin zona ni franja,
con su envío, total, estado y pagos intactos, y no se les aplica la anticipación.

## Etapa 4 — Tienda pública, carrito y checkout por WhatsApp

Dentro de la misma app Rails, separada del panel y del portal mayorista: rutas `/tienda`,
controladores `Store::*`, layout `store` y estilos `store.scss` propios. Se visita sin iniciar
sesión. No hay referencia de la tienda de Julieta Bostal en el repositorio: se tomó solo la mecánica
pedida (checkout corto que termina en WhatsApp), con diseño propio de HANS.

### Publicación (la tienda nace cerrada)

**Tienda Minorista → Tienda online** (`/admin/tienda-minorista/tienda-online`, solo admin):

- **Cerrada** (inicial): el público ve "Próximamente" (`noindex`) en todas las páginas de la
  tienda. Los administradores con sesión la recorren en **vista previa**: catálogo, carrito y
  checkout reales; al tocar "Enviar pedido por WhatsApp" se valida y se arma todo (precios, envío,
  mensaje) con las mismas reglas, pero el pedido se arma en memoria: **no se escribe nada en la
  base** (ni siquiera se consume un número R-…). El mensaje de prueba lleva la marca "VISTA PREVIA".
- **Publicar** exige marcar una casilla de confirmación; queda registrado quién y cuándo
  (`RetailStoreSetting#published`, `published_at`, `updated_by`). Cerrarla de nuevo es un botón.
- También se configuran el **WhatsApp de HANS** (`5492235275412`, solo dígitos para wa.me) y los
  **datos para transferencia** (vacíos: si no se cargan, el cliente ve que se los pasan por WhatsApp).
- Dominio propio (más adelante): con `RETAIL_STORE_HOST=tienda.ejemplo.com` la raíz de ese dominio
  redirige a `/tienda`. Sin la variable no cambia nada.

### Catálogo

Solo `RetailProduct.for_store`: producto activo, categoría activa y foto principal. Categorías en el
orden configurado; "Destacados" arriba si hay productos destacados. Precio minorista propio (nunca
el mayorista). Detalle con galería, descripción, categoría y cantidad (1 a 99). Las fotos son las
versiones optimizadas (`card` y `detail`, WebP) servidas **a través de HANS en modo proxy** de
Active Storage (`/rails/active_storage/representations/proxy/...`), con caché pública: el bucket R2
sigue privado y no hay URLs firmadas que venzan en el catálogo.

### Carrito (`Retail::StoreCart`)

Vive en la sesión (cookie cifrada de Rails): sobrevive a la navegación y a las recargas. Guarda solo
`{ id de producto de la tienda => cantidad }`; precios y totales se consultan siempre en el
servidor. Hasta 30 productos distintos y 99 unidades por producto. Lo que deja de estar publicado
se saca solo y se avisa. No reserva ni descuenta stock. Es independiente del carrito mayorista.

### Checkout (`/tienda/finalizar`)

Nombre y apellido, celular con WhatsApp, email, modalidad, fecha (solo fechas válidas de
`RetailFulfillment::Options`, con la franja del día), zona con cobertura y precio y dirección (envío),
forma de pago (**Transferencia bancaria** o **Efectivo**: solo indica cómo quiere pagar; no registra
pagos) y notas opcionales ("Texto para la torta, observaciones, alergias, etc."). Sin cuenta ni
contraseña. El resumen muestra subtotal, envío y total (ayuda visual; el servidor recalcula todo).

Al tocar **"Enviar pedido por WhatsApp"**: `Retail::PlaceStoreOrder` valida datos, productos
publicados, cantidades, fecha, zona y dirección, toma los precios vigentes del catálogo y el envío de
la zona, y crea el pedido **Pendiente de confirmación** (`source: store`). Recién después se muestra
"Pedido recibido". Cada ítem guarda el producto de la tienda (`retail_product_id`), su nombre y su
precio; si el producto de la tienda está vinculado a un producto mayorista **activo**, el ítem entra
como ese producto (producción y stock al confirmarse); si no, como producto especial.

Compradores: los datos quedan en el pedido (como en la Etapa 1). No se crean ni se vinculan
clientes mayoristas (`Customer`): no hay cuentas de clientes minoristas.

### Duplicados y abuso

- Cada checkout tiene un token (sesión + formulario) que se guarda como `request_token`
  (`store-<token>`, índice único): doble toque, recarga del POST o volver atrás desde WhatsApp
  llevan al mismo pedido. Un token que no es de la sesión no crea nada ni muestra pedidos ajenos.
- Protección CSRF de Rails en todos los formularios.
- Campo trampa invisible (honeypot) y límite por IP (`Retail::StoreThrottle`: 5 pedidos cada
  30 minutos, 20 envíos del checkout y 120 cambios de carrito cada 10 minutos; en memoria de cada
  dyno).

### Pedido recibido y WhatsApp

`/tienda/pedido/<public_token>`: número de pedido, detalle, entrega, forma de pago, datos para
transferencia (si están cargados) y el botón verde **"Enviar pedido por WhatsApp"**. La primera vez
intenta abrir WhatsApp en otra pestaña; si el navegador lo bloquea (frecuente en celulares) avisa y
queda el botón. Se puede reabrir sin generar otro pedido. No dice que el mensaje se haya enviado o
leído (un enlace wa.me no lo permite saber). Sin caché, sin `Referer`, `noindex`; deja de mostrar el
pedido 30 días después de la fecha de entrega. Los pedidos manuales no tienen página pública.

`Retail::StoreWhatsappMessage` arma el texto **desde el pedido guardado** (productos, subtotal,
envío, total, nombre, teléfono, email, modalidad, zona, dirección, fecha, franja, forma de pago y
observaciones) y el enlace `https://wa.me/5492235275412?text=<texto codificado>`. Sin API de Meta ni
webhooks.

### En el panel

Los pedidos aparecen en **Pedidos Minoristas** como "Tienda online · Pendiente de confirmación", con
email, zona, franja, forma de pago y notas. Se confirman o rechazan con el flujo existente; abrir
WhatsApp no confirma ni paga nada. Producción, stock, pagos y reportes no cambian.

### Pedidos existentes

La migración solo agrega: `retail_store_settings` (cerrada), `retail_orders.buyer_email` y
`retail_order_items.retail_product_id` (opcionales). Los pedidos anteriores no cambian.

## Fotografías: Cloudflare R2 + Active Storage

**Estado:** conectado y habilitado en producción (`RETAIL_PHOTOS_ENABLED=true`, verificado con
`retail_catalog:check_storage`). Lo que sigue documenta cómo funciona y cómo se conectó.
Sin R2, producción usa `:local` y **bloquea la subida de fotos** (`RetailCatalog::PhotoStorage`):
el disco de Heroku se borra en cada deploy/reinicio y no se aceptan fotos que se perderían. HANS
arranca igual y el resto del catálogo funciona. Desarrollo y tests usan disco local.

Variables de entorno (Heroku, nunca en el repo):

| Variable | Qué es |
|---|---|
| `R2_ACCOUNT_ID` | Account ID de Cloudflare (arma el endpoint `https://<id>.r2.cloudflarestorage.com`) |
| `R2_BUCKET` | Nombre del bucket |
| `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` | Token de API de R2 con permiso de lectura y escritura sobre ese bucket |
| `R2_ENDPOINT` | Opcional: endpoint explícito (por ejemplo, jurisdicción UE) |
| `RETAIL_PHOTOS_ENABLED` | `true` recién después de verificar el bucket con la tarea de abajo |

Producción usa R2 solo si están las cuatro primeras **y** `RETAIL_PHOTOS_ENABLED=true`.

### Paso a paso para conectarlo

1. Entrar (o crear la cuenta) en dash.cloudflare.com → **R2 Object Storage** y activar R2. Cloudflare
   puede pedir un medio de pago aunque el uso entre en el plan gratuito.
2. **Create bucket**: por ejemplo `hans-tienda-fotos`, ubicación automática, **sin acceso público**.
3. **Manage R2 API Tokens → Create API token**: permiso *Object Read & Write*, limitado a ese bucket.
   Guardar el *Access Key ID* y el *Secret Access Key* (el secreto se muestra una sola vez). El
   *Account ID* está en la página de R2.
4. Cargar las variables en Heroku (sin habilitar todavía):
   `heroku config:set R2_ACCOUNT_ID=… R2_BUCKET=hans-tienda-fotos R2_ACCESS_KEY_ID=… R2_SECRET_ACCESS_KEY=… -a hans`
5. Verificar: `heroku run bin/rails retail_catalog:check_storage -a hans` (sube, lee y borra un objeto
   de prueba). Tiene que responder `OK`.
6. Habilitar: `heroku config:set RETAIL_PHOTOS_ENABLED=true -a hans` (reinicia la app). Desde ese
   momento aparece "Agregar fotos" en cada producto.

No hace falta CORS: las fotos se suben a través de HANS, no directo desde el navegador al bucket.

### URLs de las imágenes (decisión)

- **Ahora (administrador):** bucket **privado** y URLs de Active Storage en modo *redirect*: HANS
  responde con una URL firmada de R2 que vence a los pocos minutos. Nada queda público ni listable.
- **Tienda pública (Etapa 4):** versiones optimizadas vía HANS en modo *proxy* con caché pública
  de larga duración (el bucket sigue privado). Si el tráfico crece, se puede pasar a un dominio
  público controlado conectado a R2 con la caché de Cloudflare.

### Costos (verificar en la página de precios de Cloudflare)

R2 cobra por almacenamiento (GB-mes) y por operaciones (clase A: escrituras/listados; clase B:
lecturas); la salida de datos no se cobra. Hay un nivel gratuito mensual, pero **no es ilimitado**
y sus límites pueden cambiar. Con un catálogo de decenas o pocos cientos de productos y fotos
optimizadas, el volumen esperado es bajo; igual conviene revisar el panel de uso de R2.

## Decisión original para la Etapa 2 — Fotografías

**Cloudflare R2 con Active Storage.** Las fotos se guardan fuera de PostgreSQL y fuera del disco
de Heroku (efímero: se borra en cada deploy o reinicio del dyno). Los comprobantes de
Administración siguen en PostgreSQL (`AdministrationAttachment`) y no cambian.
