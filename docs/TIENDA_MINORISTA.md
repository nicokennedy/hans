# Tienda online minorista — estado y decisiones

## Etapas

| Etapa | Estado |
|---|---|
| 0. Suite de tests confiable | Hecha (ver `docs/KNOWN_TEST_FAILURES.md`) |
| 1. Confirmación de pedidos minoristas | Hecha: origen manual/tienda, pendiente → confirmado / rechazado, solo los confirmados cuentan para producción, stock y el resumen financiero |
| 2. Catálogo minorista, precios y fotos | Hecha: administrador en Tienda Minorista → Productos / Categorías. Las fotos quedan bloqueadas en producción hasta conectar Cloudflare R2 (ver abajo) |
| 3. Reglas de retiro y delivery | Pendiente |
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

## Fotografías: Cloudflare R2 + Active Storage

**Estado:** integración lista, **no habilitada en producción** (todavía no hay cuenta ni credenciales).
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
