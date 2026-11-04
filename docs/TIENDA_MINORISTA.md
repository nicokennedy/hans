# Tienda online minorista — estado y decisiones

## Etapas

| Etapa | Estado |
|---|---|
| 0. Suite de tests confiable | Hecha (ver `docs/KNOWN_TEST_FAILURES.md`) |
| 1. Confirmación de pedidos minoristas | Hecha: origen manual/tienda, pendiente → confirmado / rechazado, solo los confirmados cuentan para producción, stock y el resumen financiero |
| 2. Catálogo minorista, precios y fotos | Hecha: administrador en Tienda Minorista → Productos / Categorías. Fotos en Cloudflare R2 (conectado y habilitado en producción) |
| 3. Reglas de retiro y delivery | Hecha: Tienda Minorista → Entregas (ver abajo) |
| 4. Tienda pública, carrito, checkout y WhatsApp | Pendiente |
| 5. Opcionales (stock, pago online, automatizaciones) | Pendiente |

## Base que deja la Etapa 1 para la tienda

- Un pedido de la tienda se crea con `Retail::SaveOrder.call(..., source: "store", request_token: ...)`:
  nace "Pendiente de confirmación" y no suma a producción, stock ni al resumen hasta que el equipo
  lo confirma (`Retail::ChangeConfirmation`). Rechazar exige motivo y es definitivo.
- `request_token` (único) hace idempotente el checkout: el mismo token devuelve el pedido ya creado.
- `public_token` (32 caracteres, único) es el identificador para la futura página pública de
  confirmación del pedido: nunca se expone el id.
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
- `Retail::PlaceStoreOrder.call(attributes:, items:, request_token:)` → **la única entrada para crear
  pedidos de la tienda**: vuelve a validar fecha, zona y dirección en el servidor, ignora cualquier
  importe que mande el cliente, guarda zona/franja/costo y crea el pedido "Pendiente de
  confirmación" (idempotente por `request_token`). Los ítems con precio de catálogo minorista se
  arman en la Etapa 4 (nunca con precios del cliente).
- `Retail::SaveOrder` sigue siendo el camino del equipo: los pedidos manuales pueden tener cualquier
  fecha y otro costo de envío (pedidos especiales, solo admin). En el formulario hay una "Zona de
  envío" opcional que completa el envío con el precio de la zona.

### Pedidos existentes

La migración solo agrega columnas opcionales: los pedidos anteriores quedan sin zona ni franja,
con su envío, total, estado y pagos intactos, y no se les aplica la anticipación.

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
- **Tienda pública (Etapa 4), a decidir allí:** servir las versiones optimizadas desde un dominio
  público controlado (dominio propio conectado a R2, con la caché de Cloudflare) o vía HANS en modo
  *proxy* con cabeceras de caché. Se elige junto con el dominio de la tienda; el modo *redirect*
  firmado no conviene para el catálogo porque las URLs vencen y no se cachean bien.

### Costos (verificar en la página de precios de Cloudflare)

R2 cobra por almacenamiento (GB-mes) y por operaciones (clase A: escrituras/listados; clase B:
lecturas); la salida de datos no se cobra. Hay un nivel gratuito mensual, pero **no es ilimitado**
y sus límites pueden cambiar. Con un catálogo de decenas o pocos cientos de productos y fotos
optimizadas, el volumen esperado es bajo; igual conviene revisar el panel de uso de R2.

## Decisión original para la Etapa 2 — Fotografías

**Cloudflare R2 con Active Storage.** Las fotos se guardan fuera de PostgreSQL y fuera del disco
de Heroku (efímero: se borra en cada deploy o reinicio del dyno). Los comprobantes de
Administración siguen en PostgreSQL (`AdministrationAttachment`) y no cambian.
