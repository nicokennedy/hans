# Tienda online minorista — estado y decisiones

## Etapas

| Etapa | Estado |
|---|---|
| 0. Suite de tests confiable | Hecha (ver `docs/KNOWN_TEST_FAILURES.md`) |
| 1. Confirmación de pedidos minoristas | Hecha: origen manual/tienda, pendiente → confirmado / rechazado, solo los confirmados cuentan para producción, stock y el resumen financiero |
| 2. Catálogo minorista, precios y fotos | Pendiente de autorización |
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

## Decisión para la Etapa 2 — Fotografías (provisoria, sin implementar)

**Cloudflare R2 con Active Storage.** Las fotos se guardan fuera de PostgreSQL y fuera del disco
de Heroku (efímero: se borra en cada deploy o reinicio del dyno).

Al implementarla:

- Instalar Active Storage (`active_storage:install`, migración nueva) y configurar un servicio S3
  compatible apuntando a R2 en `config/storage.yml`; `config.active_storage.service` de producción
  pasa de `:local` a ese servicio. Credenciales en variables de entorno de Heroku, nunca en el repo.
- Administración desde HANS: subir, reemplazar, ordenar y eliminar fotos de cada producto de la tienda.
- Validar formato (JPG, PNG, WEBP) y tamaño máximo; generar variantes optimizadas para celular
  (requiere `image_processing` y libvips en Heroku).
- Hoy no hay Active Storage instalado ni tablas `active_storage_*` en producción; los comprobantes
  de Administración usan su propio almacenamiento en PostgreSQL (`AdministrationAttachment`) y no
  cambian.
