# Repartos y Rendiciones — auditoría, arquitectura y plan (Fase 0)

> Estado: **diseño aprobado; R0 y R1 en curso** en la rama `repartos-r0-r1` (sin push, sin
> deploy, sin cambios en producción). Decisiones de negocio D1–D9 aprobadas: ver §8.
> Auditoría original hecha sobre `main` (`96a5c36`).

---

## 1. Estado actual: qué existe y qué se reutiliza

| Área | Qué hay hoy | Uso en Repartos |
|---|---|---|
| **Pedidos mayoristas** | `Order` con `delivery_date`, `status` (incluye `delivered`), `total_cents`, `amount_paid_cents`, `payment_status` derivado de los pagos. Scope `Order.for_delivery_date(date)` (sin cancelados), el mismo que usa Producción. | Fuente de las paradas del día. **No se modifica el modelo.** |
| **Stock** | `Stock::DispatchReconciler` descuenta por **fecha de entrega + corte de las 13 h**, no por el estado "Entregado". | Marcar "entregado" desde el reparto **no puede** generar un doble descuento de stock. Verificado en el código. |
| **Cobros / cuenta corriente** | `CustomerPayment` (el ingreso real, una sola vez) + `Payment` (aplicaciones a pedidos). `CustomerAccounts::RegisterPayment`: transacción, bloqueo del cliente y los pedidos, `request_token` único contra doble envío, sobrante = **saldo a favor**. `CustomerAccounts::Distribution.suggest`: reparte del pedido más antiguo al más nuevo. `VoidPayment`: anula con motivo y conserva el registro. `ApplyCredit`: administración aplica saldo a favor después. | **Es exactamente lo que necesita el cobro en efectivo.** Cada cobro del repartidor = un `CustomerPayment` en efectivo. No se crea lógica financiera nueva. |
| **Pago individual por pedido** | `Admin::PaymentsController#destroy` **borra** el `Payment` (sin motivo ni registro). | **No se usa** para el reparto: no es auditable. |
| **Gastos** | `Expense` → `Obligation` → `OutgoingPayment` (método `cash`) vía `Finance::SaveExpense`. Categorías `ExpenseCategory`. Comprobantes con `AdministrationAttachment`. | El gasto del recorrido se pasa a un `Expense` real **cuando administración confirma la rendición** (ver §5). |
| **Flujo de caja** | `Finance::PeriodResult` ya cuenta como cobrado cada `CustomerPayment` una sola vez, por `paid_on`. | Los cobros del reparto aparecen solos en el resumen de Administración, sin cambios. |
| **Usuarios y roles** | Devise + `User#role`: `customer`, `admin`, `production` (solo lectura). Filtros `require_admin!`, `require_admin_or_production!`, `require_customer!`. `ensure_active_customer!` expulsa a todo usuario que no sea admin/production y no tenga cliente. | Se agrega el rol **`driver` (repartidor)**. `envios@hans.com` **no existe** en seeds ni en el código; se crea en la etapa R0 (en producción, con tu autorización). |
| **Sesión** | `rememberable` activo, `remember_for` por defecto (2 semanas), sin `timeout_in`. | Para el celular corporativo: "recordarme" siempre activo y vencimiento largo **solo para el rol repartidor** (Devise permite sobreescribir `remember_expires_at` por usuario). |
| **Remitos** | Partial `orders/_receipt`, PNG y PDF masivo generados **en el navegador** (`receipt_export`, `bulk_receipts`), con soporte específico para iPhone/Safari. Dos copias: "una vuelve firmada con el repartidor". | Se reutiliza tal cual para "Ver remito" del repartidor y para la hoja de ruta. |
| **Archivos** | (a) `AdministrationAttachment`: guarda el archivo **en Postgres**, máx. 3 MB, tipo verificado por los bytes. (b) Active Storage: en producción usa **R2 solo si** `RETAIL_PHOTOS_ENABLED=true`; si no, disco local de Heroku (se borra). | Fotos de remitos y comprobantes: ver §5.4 (recomendación R2, alternativa Postgres). |
| **Historial** | Tabla `order_events` **existe pero nada la usa**. Hay historiales específicos (`retail_order_status_changes`, `raw_material_cost_changes`). | Se crea un historial propio del reparto (`delivery_events`) y, opcionalmente, se empieza a escribir `order_events` al entregar. |
| **PWA / iPhone** | `manifest.json`, `apple-mobile-web-app-capable`, íconos, `service-worker.js` (push). | El acceso directo desde la pantalla de inicio ya funciona; se ajusta `start_url` según el rol. |
| **Direcciones** | `customers.address` (texto libre, opcional). Los minoristas tienen `retail_orders.address`. | Dirección de la parada + botón Google Maps (`https://maps.google.com/?q=...`). |
| **Tests** | Minitest, suite verde (6 tests con `skip` documentados en `KNOWN_TEST_FAILURES.md`). | Cada etapa agrega sus tests de modelo, servicio y controlador. |

**Conclusión de la auditoría:** el 80 % de lo financiero ya existe y está bien protegido
(transacciones, bloqueos, idempotencia, anulación con motivo). Lo nuevo es **logístico**
(recorrido, paradas, entregas) y la **custodia del efectivo** (rendición). La rendición no es
un ingreso nuevo: es el control de que el efectivo ya cobrado llegó a HANS.

---

## 2. Arquitectura propuesta

### 2.1 Modelos nuevos

```
User (role: driver) ─┐
                     ▼
DeliveryRoute  (un recorrido: fecha + repartidor)
 ├── DeliveryStop*          (paradas ordenadas; pedido o parada manual)
 │    ├── DeliveryCollection*   (cobros en efectivo) ──► CustomerPayment (existente)
 │    └── DeliveryPhoto*        (remito firmado / incidencia)
 ├── DeliveryExpense*       (gastos del recorrido) ──► Expense (existente, al confirmar)
 ├── DeliveryCashMovement*  (ajustes autorizados; solo admin — sin fondo de cambio, D4)
 └── DeliveryEvent*         (historial inmutable de todo lo anterior)
```

**`delivery_routes`** — `date`, `driver_id` (User), `status`
(`draft` → `in_progress` → `submitted` → `confirmed`), `created_by_id`, `started_at`,
`submitted_at`, `confirmed_at`, `confirmed_by_id`, foto congelada al enviar
(`expected_cash_cents`, `collected_cents`, `expenses_cents`, `adjustments_cents`),
`counted_cash_cents`, `difference_cents` (diferencia de caja, D3), `confirmation_note`,
`lock_version`. Índice único `(date, driver_id)`: un recorrido por repartidor por día,
preparado para varios repartidores.

**`delivery_stops`** — `delivery_route_id`, `position`, `kind`
(`order`, `supplies_pickup`, `purchase`, `errand`, `other`), `order_id` (opcional),
`customer_id` (opcional), `title`, `address`, `notes`; estado logístico `delivery_status`
(`pending`, `delivered`, `not_delivered`, `done`), `not_delivered_reason`,
`delivered_at`, `delivered_by_id`; exclusión: `removed_at`, `removed_by_id`,
`removal_kind` (`owners_deliver`, `rescheduled`, `other`), `removal_reason`.
**Índice único parcial** `order_id WHERE removed_at IS NULL`: un pedido no puede estar en
dos recorridos a la vez. Quitar una parada **nunca** borra la fila ni toca el pedido.

**`delivery_collections`** — `delivery_route_id`, `delivery_stop_id`, `customer_id`,
`amount_cents`, `mode` (`this_order`, `this_and_previous`, `unknown`),
`customer_payment_id`, `request_token` (único), `created_by_id`, anulación
(`voided_at`, `voided_by_id`, `void_reason`), `replaces_id` (la corrección apunta al cobro
que reemplaza: así quedan importe original, corregido, motivo, usuario y hora).

**`delivery_photos`** — `delivery_route_id`, `delivery_stop_id`, `kind`
(`signed_receipt`, `incident`, `expense_receipt`), `delivery_expense_id` (opcional),
`taken_by_id`, `request_token`, archivo (ver §5.4). Pedido, cliente, repartidor y fecha
se derivan de la parada y el recorrido (no se duplican).

**`delivery_expenses`** — `delivery_route_id`, `concept` (`fuel`, `supplies`, `other`),
`description` (opcional), `amount_cents` (siempre pagado con el efectivo del reparto, D2),
`expense_id` (el `Expense` que crea administración al confirmar; único),
`request_token`, anulación y `replaces_id` igual que los cobros.

**`delivery_cash_movements`** — `delivery_route_id`, `amount_cents` (con signo), `reason`,
`created_by_id`. Solo administración y solo para ajustes autorizados excepcionales. No hay
fondo de cambio (D4): el repartidor sale sin efectivo y no ve este concepto.

**`delivery_events`** — `delivery_route_id`, `delivery_stop_id`, `user_id`, `event_type`,
`data` (jsonb: antes/después), `reason`, `created_at`. Solo inserción.

**Cambios en tablas existentes:** solo agregar el valor `driver` al enum de `User#role`
(es un string, sin migración de datos). Nada más.

### 2.2 Servicios (`app/services/delivery_routes/`)

| Servicio | Qué hace |
|---|---|
| `Build` | Crea el recorrido de una fecha con `Order.for_delivery_date`, ordenado por la última posición conocida de cada cliente en recorridos anteriores (los nuevos, al final). |
| `ArrangeStops` | Subir/bajar/mover, agregar y quitar paradas; registra evento con motivo si el recorrido ya empezó. |
| `RecordDelivery` | Entregué / No pude / Hecho. Pasa el pedido a "Entregado" (ver decisión D6). No toca stock ni pagos. |
| `RecordCollection` | Llama a `CustomerAccounts::RegisterPayment` (efectivo, `paid_on` = fecha del recorrido) con la distribución según el modo, y guarda el `DeliveryCollection` en **la misma transacción**. |
| `CorrectCollection` | Anula el `CustomerPayment` anterior con `CustomerAccounts::VoidPayment` y registra el nuevo, en una transacción. Nunca hay dos cobros vigentes por el mismo efectivo. |
| `CashSummary` | Calcula la rendición desde los registros (nunca se edita a mano). |
| `Submit` / `Reopen` / `Confirm` | Cambios de estado con bloqueo de fila, congelado de totales y evento. |
| `PostExpenses` | Al confirmar: crea los `Expense` con `Finance::SaveExpense` (pago en efectivo si fue con la plata del recorrido). |

### 2.3 Permisos

- Nuevo rol `driver`. `User#driver?`, filtro `require_driver!`.
- `ensure_active_customer!` deja pasar al repartidor (hoy lo expulsaría por no tener cliente).
- `after_sign_in_path_for`: repartidor → `/reparto`.
- Namespace propio **`/reparto`** (`Reparto::*Controller`, layout `reparto`), separado de
  `/admin`. Todo se busca por `current_user.delivery_routes`, así un repartidor nunca ve
  recorridos de otro.
- El repartidor **no** entra a `/admin`; `require_admin!` ya lo redirige.
- Administración: `/admin/repartos` (`Admin::DeliveryRoutesController`), solo `admin`.
  Producción no ve importes (mismo criterio actual).

| Acción | Repartidor | Admin |
|---|---|---|
| Ver su recorrido, pedido, remito | Sí (solo el suyo) | Todos |
| Entregué / No pude | Sí, mientras está "En reparto" | Sí, con motivo |
| Cobro en efectivo / corregirlo | Sí, mientras está "En reparto" | Sí, siempre, con motivo |
| Gasto / foto | Sí, mientras está "En reparto" | Sí |
| Enviar rendición | Sí | — |
| Ajuste, confirmar, reabrir | No | Sí |
| Precios, pedidos, saldos, transferencias | **No** | Como hoy |

---

## 3. Flujos funcionales

### 3.1 Administración — preparar el recorrido

1. **Repartos → elegir fecha → "Armar recorrido"**. Se crean las paradas de todos los
   pedidos mayoristas del día (sin cancelados), en el orden del último recorrido.
2. Cada parada muestra: orden, cliente, pedido, total, saldo del pedido, deuda anterior del
   cliente, dirección y observaciones.
3. Botones **▲ Subir / ▼ Bajar** en cada fila (más arrastrar en computadora).
4. **+ Agregar parada**: pedido de otra fecha / retiro de insumos / compra / gestión / otra.
5. **Quitar del recorrido** → pregunta *¿quién lo entrega?*: "Lo entregan las dueñas",
   "Pasa a otro día", "Otro (escribir motivo)". El pedido no se toca.
6. Abajo, siempre visibles, tres bloques:
   - **En el recorrido** (N paradas).
   - **Fuera del recorrido** (con quién lo entrega y botón "Marcar entregado").
   - **⚠ Pedidos del día sin asignar**: pedidos con fecha de hoy que no están en ningún
     recorrido ni fueron excluidos. Mientras haya alguno, se muestra un aviso en el
     panel de Repartos. Así nada queda olvidado.
7. **Imprimir hoja de ruta** (orden, cliente, dirección, total, casillero para anotar).
8. **"Dar el recorrido al repartidor"** → estado *En reparto*. Desde acá, todo cambio
   pide motivo y queda en el historial.

### 3.2 Repartidor — el día

Recorrido → Parada → Entregué / No pude → ¿Te pagaron? → (importe | foto del remito)
→ "Listo, quedó guardado" → Siguiente parada. Al final: Gastos → "Mi rendición" →
"Terminé el reparto". Detalle de pantallas en §4.

### 3.3 Cierre

| Estado | Quién | Qué pasa |
|---|---|---|
| **En reparto** | Repartidor | Registra entregas, cobros, fotos, gastos y corrige. |
| **Rendición enviada** | Repartidor toca "Terminé" | Se congelan cobros y gastos; se guarda el efectivo esperado. El repartidor solo puede mirar. Admin puede **reabrir** con motivo si hay que corregir algo del repartidor. |
| **Rendición confirmada** | Admin | Cuenta el dinero, escribe cuánto recibió. Se muestra: cobrado, gastos, ajustes, **esperado**, **recibido**, **diferencia de caja**. Si hay diferencia, motivo obligatorio; queda registrada como diferencia de caja (nunca como gasto, D3). Se crean los gastos en Administración. Queda cerrada. |

Corrección después de confirmar: solo admin, anulando el cobro con motivo (el
`CustomerPayment` se anula con el mecanismo existente) y registrando un ajuste en el
recorrido; la confirmación original queda en el historial.

---

## 4. Diseño UX móvil del repartidor

Reglas aplicadas: una decisión por pantalla, botones de alto completo (≥ 64 px), texto
≥ 20 px, alto contraste, cada estado con **palabra + ícono + color** (nunca solo color),
sin tablas ni desplegables, sin escribir salvo importes. Cada botón que guarda se
desactiva al tocarlo y muestra "Guardando…". Siempre arriba: **"◀ Volver a la lista"**.

```
┌──────────────────────────┐   ┌──────────────────────────┐   ┌──────────────────────────┐
│ REPARTO DE HOY           │   │ ◀ Volver a la lista      │   │ ◀ Volver                 │
│ Martes 18 de noviembre   │   │                          │   │                          │
│ Vas 3 de 9 paradas       │   │ CAFÉ HONEY               │   │ CAFÉ HONEY               │
│                          │   │ Parada 4 de 9            │   │                          │
│ PRÓXIMA PARADA           │   │ Av. Colón 1234           │   │ ¿Pudiste entregar        │
│ ┌──────────────────────┐ │   │ ┌──────────────────────┐ │   │  el pedido?              │
│ │ CAFÉ HONEY           │ │   │ │  📍 CÓMO LLEGAR      │ │   │                          │
│ │ Av. Colón 1234       │ │   │ └──────────────────────┘ │   │ ┌──────────────────────┐ │
│ └──────────────────────┘ │   │ LLEVÁS:                  │   │ │ ✔ SÍ, LO ENTREGUÉ    │ │
│ ┌──────────────────────┐ │   │  12  Medialunas          │   │ └──────────────────────┘ │
│ │   VER PEDIDO   ▶     │ │   │   6  Budín de limón      │   │                          │
│ └──────────────────────┘ │   │   2  Torta de ricota     │   │                          │
│ ┌──────────────────────┐ │   │                          │   │ ┌──────────────────────┐ │
│ │ 📍 CÓMO LLEGAR       │ │   │ TOTAL DEL PEDIDO         │   │ │ ✖ NO PUDE ENTREGARLO │ │
│ └──────────────────────┘ │   │ $ 48.500                 │   │ └──────────────────────┘ │
│                          │   │ ┌──────────────────────┐ │   │                          │
│ VER TODAS LAS PARADAS    │   │ │  YA ESTOY ACÁ  ▶     │ │   │                          │
│ MI RENDICIÓN · GASTOS    │   │ └──────────────────────┘ │   │                          │
└──────────────────────────┘   │ Ver remito               │   └──────────────────────────┘
        A. Inicio              └──────────────────────────┘       C. ¿Entregaste?
                                      B. Pedido
```

```
┌──────────────────────────┐   ┌──────────────────────────┐   ┌──────────────────────────┐
│ CAFÉ HONEY               │   │ CAFÉ HONEY               │   │ CAFÉ HONEY               │
│                          │   │                          │   │                          │
│ ¿Te dieron plata         │   │ ¿Cuánto te dieron?       │   │ Sacale una foto al       │
│  en efectivo?            │   │                          │   │ remito firmado           │
│                          │   │ ┌──────────────────────┐ │   │                          │
│ ┌──────────────────────┐ │   │ │ $ 48.500 (el pedido) │ │   │ ┌──────────────────────┐ │
│ │ $ SÍ, ME PAGARON     │ │   │ └──────────────────────┘ │   │ │ 📷 SACAR FOTO        │ │
│ └──────────────────────┘ │   │ ┌──────────────────────┐ │   │ └──────────────────────┘ │
│                          │   │ │ OTRO IMPORTE         │ │   │                          │
│ ┌──────────────────────┐ │   │ └──────────────────────┘ │   │ El cliente no firmó      │
│ │ ✖ NO ME PAGARON      │ │   │                          │   │ No puedo sacar la foto   │
│ └──────────────────────┘ │   │ Este cliente además debe │   │                          │
│                          │   │ $ 30.000 de antes.       │   │                          │
│                          │   │ ┌──────────────────────┐ │   │                          │
│                          │   │ │ PAGÓ TODO: $ 78.500  │ │   │                          │
│                          │   │ └──────────────────────┘ │   │                          │
└──────────────────────────┘   └──────────────────────────┘   └──────────────────────────┘
     D. ¿Te pagaron?                E. Importe                  F. Foto (si no pagó
                                                                   o pagó una parte)
```

```
┌──────────────────────────┐   ┌──────────────────────────┐   ┌──────────────────────────┐
│ ¿Recibiste               │   │                          │   │ MI RENDICIÓN             │
│     $ 48.500             │   │        ✔                 │   │                          │
│ de CAFÉ HONEY?           │   │                          │   │ Cobraste      $ 312.000  │
│                          │   │  LISTO,                  │   │                          │
│ ┌──────────────────────┐ │   │  QUEDÓ GUARDADO          │   │ Gastaste      $  15.000  │
│ │ ✔ SÍ, ES CORRECTO    │ │   │                          │   │                          │
│ └──────────────────────┘ │   │ Cobraste $ 48.500        │   │ ─────────────────────── │
│                          │   │                          │   │ TENÉS QUE                │
│ ┌──────────────────────┐ │   │ ┌──────────────────────┐ │   │ ENTREGAR      $ 307.000  │
│ │ ✎ NO, CAMBIAR        │ │   │ │ SIGUIENTE PARADA ▶   │ │   │                          │
│ └──────────────────────┘ │   │ └──────────────────────┘ │   │ Ver de dónde sale ▶      │
│                          │   │                          │   │ ┌──────────────────────┐ │
│                          │   │ Me equivoqué, corregir   │   │ │ TERMINÉ EL REPARTO   │ │
└──────────────────────────┘   └──────────────────────────┘   │ └──────────────────────┘ │
     G. Confirmar importe           H. Listo                  └──────────────────────────┘
                                                                    I. Rendición
```

Detalles de diseño:

- **"Otro importe"** abre un teclado numérico grande (`inputmode="numeric"`), sin
  centavos, con el monto en letras grandes mientras escribe.
- **"Pagó todo"** solo aparece si el cliente tiene deuda anterior; reparte del pedido más
  viejo al más nuevo (lógica existente). Si el importe no coincide con nada, se pregunta:
  *"¿Es para este pedido?"* → **Sí** / **No sé** (queda "a revisar" por administración).
- En el prototipo (R1) la pregunta **"¿Pudiste entregar el pedido?"** está al pie de la
  pantalla del pedido (B y C juntas): un paso menos. Desde la lista nunca se marca nada
  sin abrir la parada.
- **No pude entregarlo** → un toque para el motivo: "Estaba cerrado", "No lo quisieron",
  "No llegué", "Otro" → "Listo, quedó anotado". No se pregunta por cobros: si un cliente
  ya había pagado antes, eso lo ve administración (estados logístico y financiero
  independientes).
- **Foto:** `<input type="file" accept="image/*" capture="environment">` abre la cámara del
  iPhone directo. Se achica en el celular (~1600 px, JPEG) antes de subir.
- **Lista de paradas:** tarjetas grandes en orden, cada una con texto de estado:
  "Falta", "Entregado · Pagó $48.500", "Entregado · No pagó · Foto ✔", "No entregado".
  Tocar una parada anterior permite verla y corregir.
- **Gastos:** tres botones grandes "⛽ Nafta", "🛒 Insumos", "Otro" → importe → confirmar →
  foto del ticket (opcional). Siempre se descuentan del efectivo del reparto (D2).
- **Terminé el reparto:** confirma "Vas a entregar $ 307.000. Después no vas a poder
  cambiar nada." **Sí, terminé / Volver**. Si quedan paradas sin marcar o fotos faltantes,
  lo dice en palabras antes de confirmar.

### Escenarios evaluados

| # | Escenario | Cómo se resuelve |
|---|---|---|
| 1 | Entrega y cobra exacto | C → D → E (botón con el importe) → G → H. **5 toques.** |
| 2 | Entrega y no cobra | C → D "No me pagaron" → F foto → H. |
| 3 | Pago parcial | E "Otro importe" → G → F (pide foto porque queda saldo) → H. |
| 4 | Efectivo por varios pedidos | E "Pagó todo" (o importe libre) → reparto automático de más viejo a más nuevo con la lógica existente. |
| 5 | Se equivoca y corrige | H "Me equivoqué" o desde la lista → nuevo importe → motivo de un toque ("Me equivoqué de número", "El cliente me dio otro monto", "Otro"). Anula y reemplaza; queda historial. |
| 6 | Foto del remito | F → cámara → "Foto guardada ✔". |
| 7 | La foto no sube | La entrega y el cobro **ya están guardados** (se guardan antes). La parada queda "Falta subir la foto" con botón "Reintentar". El envío de la rendición avisa pero no se traba. |
| 8 | Sin internet | Ver §6: mensaje claro "No se guardó", el formulario conserva lo cargado, botón "Probar de nuevo". Respaldo: la hoja de ruta impresa. |
| 9 | Doble toque | Botón desactivado al primer toque + `request_token` único en el servidor: el segundo envío devuelve el mismo registro. |
| 10 | Volver a una parada | "◀ Volver a la lista" siempre visible; cualquier parada se puede abrir. |
| 11 | Gasto de nafta | Gastos → ⛽ Nafta → importe → confirmar → foto (opcional) → listo. |
| 12 | ¿Cuánto entrego? | Pantalla I, con el detalle de cada cobro y gasto a un toque. |
| 13 | Modificar rendición enviada | Los botones de cambio desaparecen; se muestra "Ya enviaste la rendición. Si algo está mal, avisale a administración." El servidor también lo rechaza. |
| 14 | Admin quita una parada | Desaparece de la lista del repartidor al recargar; si ya tenía entregas o cobros, **no se puede quitar**: solo marcarla "no corresponde" con motivo, y los cobros se corrigen por separado. |
| 15 | La entregan las dueñas | Admin la quita con "Lo entregan las dueñas"; queda en "Fuera del recorrido" con botón "Marcar entregado"; si pagan, se registra en la cuenta corriente como hoy. No entra en la rendición. |

---

## 5. Integración financiera (sin duplicar registros)

### 5.1 Cobros en efectivo

- **Cada cobro del repartidor = un `CustomerPayment`** (método "Efectivo contraentrega",
  `paid_on` = fecha del recorrido, `user` = repartidor, nota "Reparto 18/11 · parada 4"),
  registrado con `CustomerAccounts::RegisterPayment`. Se registra **en el momento**, no al
  cerrar: administración ve el saldo actualizado ese mismo día.
- Distribución según lo que eligió el repartidor:
  - *Este pedido* → todo al pedido de la parada (hasta su saldo).
  - *Pagó todo / este y anteriores* → `Distribution.suggest` sobre los pendientes del cliente.
  - *No sé* o sobrante → sin aplicar = **saldo a favor** del cliente; la rendición lo marca
    "a revisar" y administración lo aplica con el `ApplyCredit` existente.
- No se usan pagos individuales (`Payment` suelto): no son auditables (se borran).
- Doble envío: el `request_token` del formulario va a `customer_payments.request_token`
  (índice único existente) **y** a `delivery_collections.request_token`.
- Corrección: `VoidPayment` (con motivo) + nuevo `RegisterPayment` en una sola transacción.
  Límite existente: si el saldo a favor de ese cobro ya se aplicó a otros pedidos, primero
  hay que revertir esa aplicación (caso de administración, el repartidor ve "Avisale a
  administración").
- Transferencias: el repartidor no las registra. Opcional: botón "Me dijo que transfirió"
  que solo deja una nota para administración (no toca saldos).

### 5.2 Gastos

- Durante el día se guardan como `DeliveryExpense` (informados por el repartidor).
- Al **confirmar** la rendición, administración elige la categoría (precargada: "Nafta y
  reparto", "Insumos") y `Finance::SaveExpense` crea `Expense` + `Obligation` + pago en
  efectivo si fue con la plata del recorrido. `delivery_expenses.expense_id` único: no se
  puede pasar dos veces.
- Riesgo de duplicado manual: la pantalla de Gastos de Administración mostrará "viene del
  reparto del 18/11" para que nadie lo cargue de nuevo.

### 5.3 Rendición y diferencias

```
EFECTIVO A ENTREGAR = cobros vigentes
                    − gastos del recorrido (todos pagados con ese efectivo, D2)
                    ± ajustes autorizados por administración (excepcionales)
```

- Todo sale de registros; ningún total es editable.
- Al confirmar se guarda `counted_cash_cents` y `difference_cents = contado − esperado`.
- La diferencia **no modifica** cobros de clientes y **nunca se registra como gasto**
  (D3). Queda como *diferencia de caja* en el recorrido, con usuario, fecha, motivo e
  historial, y en un listado "Diferencias de caja" de administración.
- No hay fondo de cambio (D4).

### 5.4 Fotos

- **Recomendado:** Active Storage en Cloudflare R2 (ya configurado para la tienda). Hay que
  verificar si en producción `RETAIL_PHOTOS_ENABLED=true`; si no, primero activarlo.
- **Alternativa:** `AdministrationAttachment` en Postgres (ya funciona). Con fotos
  comprimidas (~300 KB) son ~1,5 GB por año con 15 paradas diarias: hay que revisar el
  plan de Heroku Postgres.
- La foto se sube en un pedido **separado** de la entrega y del cobro: si falla, no se
  pierde nada más.

---

## 6. Riesgos

| Riesgo | Mitigación |
|---|---|
| Sin conexión: el repartidor cree que guardó | Mensaje de error grande y en palabras, nunca "Listo" sin respuesta del servidor; formulario conserva lo cargado; reintento idempotente. Etapa opcional: cola local en el celular (localStorage + reintento automático). Respaldo en papel. |
| Doble cobro por doble toque o reintento | Botón desactivado + `request_token` único en dos tablas + transacción con bloqueo. |
| Mismo pedido en dos recorridos | Índice único parcial en `delivery_stops.order_id`. |
| Pedido olvidado al quitarlo | Bloque "sin asignar" + aviso en el panel; quitar exige decir quién lo entrega. |
| Cobro en recorrido y admin registra el mismo pago | El cobro se ve al instante en la cuenta corriente y en el pedido ("Cobrado por reparto"). |
| Saldo a favor ya aplicado impide corregir | Mensaje claro al repartidor; corrige administración (flujo existente). |
| Inconsistencia rendición ↔ cuentas corrientes | La rendición se **calcula** desde los `DeliveryCollection` vigentes, que siempre tienen su `CustomerPayment` vigente en la misma transacción. Test que lo verifique. |
| Gastos duplicados | `expense_id` único; aviso en Gastos. |
| Celular perdido con sesión abierta | Admin cambia la contraseña de `envios@hans.com` (invalida "recordarme": `expire_all_remember_me_on_sign_out` ya está activo; se agrega invalidación al cambiar contraseña). El rol no ve información financiera global. |
| Fotos de iPhone grandes o HEIC | `accept="image/*"` hace que Safari entregue JPEG; se comprime en el navegador antes de subir; límite en servidor. |
| Fotos en disco efímero de Heroku | Bloquear la subida si el servicio no es R2 (mismo criterio que `RetailCatalog::PhotoStorage`). |
| Cambiar "Entregado" en `Order` dispara validaciones del pedido | Se probará contra pedidos reales copiados en test; si una validación vieja falla, la entrega del reparto se guarda igual y el estado del pedido se informa "a revisar". |
| Rechazo del repartidor | Prototipo clickeable probado con él **antes** de programar sus pantallas; piloto en paralelo con el papel. |

---

## 7. Plan de implementación (etapas chicas, cada una con tests y sin tocar lo existente)

| Etapa | Contenido | Criterio de aceptación |
|---|---|---|
| **R0 — Rol repartidor** | Rol `driver`, filtros, redirección al login, sesión larga en el celular, layout `reparto` vacío, `start_url` del ícono. | `envios@hans.com` (creado en desarrollo) entra y ve "Hoy no tenés reparto"; no puede abrir ninguna URL de `/admin`; clientes y admin sin cambios (suite verde). |
| **R1 — Prototipo UX** | Pantallas A–I clickeables con datos de ejemplo (sin base de datos), para probar con el repartidor en su iPhone. | El repartidor completa los escenarios 1, 2 y 4 sin ayuda. Ajustes de textos/tamaños acordados. |
| **R2 — Armado del recorrido (admin)** | Modelos `DeliveryRoute`, `DeliveryStop`, `DeliveryEvent`; generar desde la fecha; subir/bajar; agregar/quitar con motivo; bloques "fuera" y "sin asignar"; hoja de ruta imprimible; dar al repartidor. | Armar, reordenar, quitar y volver a agregar sin tocar ningún `Order`; un pedido no puede quedar en dos recorridos; todo cambio con historial. |
| **R3 — Portal: recorrido y entregas** | Pantallas A, B, C, H y lista; Google Maps; ver remito (partial existente); Entregué / No pude; estado del pedido. | Escenarios 1 (parte logística), 10, 14, 15. Un repartidor no ve recorridos ajenos (test). Stock sin cambios (test). |
| **R4 — Cobros en efectivo** | `DeliveryCollection` + `RecordCollection`/`CorrectCollection` sobre `CustomerAccounts`; pantallas D, E, G; "pagó todo"; "no sé". | Escenarios 1, 3, 4, 5, 9. Test: cuenta corriente y rendición siempre coinciden; doble envío no duplica; corrección deja un solo cobro vigente. |
| **R5 — Fotos** | `DeliveryPhoto`, cámara, compresión, reintento, "no firmó / no puedo sacar la foto". | Escenarios 2, 6, 7. Una foto fallida nunca borra la entrega ni el cobro. |
| **R6 — Gastos y rendición del repartidor** | `DeliveryExpense`, `CashSummary`, pantalla I, "Terminé el reparto". | Escenarios 11, 12, 13. El total no es editable; después de enviar todo queda en solo lectura (UI y servidor). |
| **R7 — Confirmación y auditoría (admin)** | Confirmar con dinero contado, diferencia, reabrir, ajustes, gastos → `Finance::SaveExpense`, historial legible, listado de diferencias y cobros "a revisar". | Confirmar crea los gastos una sola vez; diferencias registradas sin tocar cobros; historial completo por recorrido. |
| **R8 — Sin conexión (opcional)** | Cola local con reintento automático. | Escenario 8 sin intervención. Solo si el piloto muestra que hace falta. |
| **Piloto** | 1–2 semanas en paralelo con la rendición en papel. | Las rendiciones del sistema coinciden con las de papel. |

Cada etapa: rama propia, migraciones solo aditivas, suite completa en verde, nada en
producción ni deploy sin tu OK explícito.

---

## 8. Decisiones de negocio aprobadas (D1–D9)

| # | Decisión aprobada | Cómo impacta |
|---|---|---|
| D1 | **Solo pedidos mayoristas.** No se incorporan pedidos minoristas con envío. | `Build` usa únicamente `Order`. Las paradas manuales siguen existiendo para retiros, compras y gestiones. |
| D2 | **Gastos solo con efectivo del reparto.** Sin dinero personal ni reintegros. | Se elimina `paid_with`: todo `DeliveryExpense` descuenta del efectivo a entregar. La UI no pregunta con qué se pagó. |
| D3 | **Diferencias de caja como diferencias de caja**, nunca como gastos; identificadas y auditadas. | `difference_cents` + motivo obligatorio + evento en el historial + listado "Diferencias de caja". No se crea `Expense` por una diferencia. |
| D4 | **Sin fondo de cambio.** El repartidor sale sin efectivo. | Se quitan los anticipos del flujo y de la pantalla del repartidor. Fórmula: cobros − gastos ± ajustes excepcionales de administración. |
| D5 | **Ve las deudas anteriores del mismo cliente**, nunca las de otros, y no modifica saldos. | La parada muestra "además debe $X de pedidos anteriores" solo para ese cliente; el saldo se calcula con `CustomerAccounts::Distribution.pending_orders`. Sin pantallas de cuenta corriente para el repartidor. |
| D6 | **"Entregué" pasa el pedido a `Entregado`**, sin generar pago ni cambiar su estado financiero. | `RecordDelivery` cambia solo `orders.status` (y deja evento con usuario y hora). `payment_status` y pagos no se tocan (test obligatorio). Verificado: el stock no depende del estado. |
| D7 | **Sesión iniciada en el celular corporativo**, segura y compatible con Safari. | Implementado en R0 (ver §9). |
| D8 | **Rendición el mismo día.** Si no se envía, alerta visible en el sistema (sin notificaciones externas). | Desde R6/R7: aviso en el Panel y en Repartos para todo recorrido de un día anterior que no esté "Enviada". |
| D9 | **Foto del remito obligatoria si no paga o paga una parte**; opcional si paga todo; excepción justificada si no hay firma o no se puede subir. | Pantalla de foto obligatoria en esos casos, con dos salidas: "El cliente no quiso firmar" / "No puedo sacar la foto". La excepción queda registrada y visible para administración. |

---

## 9. R0 — preparación técnica (hecho en la rama `repartos-r0-r1`)

**Verificaciones en producción (solo lectura, `BEGIN READ ONLY … ROLLBACK`, 18/11/2026):**

| Verificación | Resultado |
|---|---|
| Usuario `envios@hans.com` | **No existe.** Usuarios: 1 admin, 1 producción, 54 clientes. No se creó nada. |
| Cloudflare R2 | **Activo** (`RETAIL_PHOTOS_ENABLED=true`, las 4 variables `R2_*` cargadas). Las 73 fotos actuales están en `cloudflare_r2`. |
| Base de datos | Heroku Postgres `essential-0`: **1 GB**, 14,7 MB usados. → Las fotos de remitos **van a R2**, no a Postgres (en Postgres llenarían el plan en menos de un año). |
| Direcciones de clientes | **Solo 1 de 54 clientes activos tiene dirección.** El botón "Cómo llegar" no sirve hasta cargarlas (tarea de administración, antes de R3). |
| Volumen | Últimos 30 días: 127 pedidos en 25 días de entrega (~5 paradas por día). |

**Cambios de código (sin migraciones; `users.role` es un string):**

- Rol `driver` en `User` (`User#driver?`). Sin cambios para `admin`, `production` ni `customer`.
- `ensure_active_customer!` deja pasar al repartidor; `require_customer!`, la redirección
  después del login y la página de inicio lo mandan a **`/reparto`**.
- `/reparto` (`Reparto::BaseController`, layout `reparto`): solo repartidor y admin (vista
  previa). El repartidor no entra a `/admin`, al carrito, a "Mis pedidos" ni al portal de
  clientes (tests).
- Pantalla inicial vacía: "Hoy no tenés reparto" + botón al prototipo (R1).
- **Sesión del celular (D7):** solo para el rol repartidor, al iniciar sesión se activa
  siempre "recordarme" con una cookie firmada, `HttpOnly`, `Secure` (producción fuerza
  HTTPS) y `SameSite=Lax`, válida **60 días y renovada con cada uso** (si el celular no se
  usa 60 días, pide la contraseña de nuevo). Funciona en Safari y en el ícono de la
  pantalla de inicio aunque iOS cierre la app. **Revocación:** cambiar la contraseña de
  `envios@hans.com` invalida la cookie en el acto; "Salir" la borra en todos los
  dispositivos. El resto de los usuarios no cambia.
- Requisito del dispositivo (no es código): el iPhone corporativo debe tener código de
  bloqueo/Face ID y "Buscar mi iPhone" activo.
- `db/seeds.rb` crea `envios@hans.com` **solo en desarrollo** (contraseña de prueba).

**Pendiente para producción (requiere tu autorización explícita, no se hizo):** crear el
usuario `envios@hans.com` con rol `driver` y una contraseña segura.

---

## 10. R1 — prototipo navegable

**Qué es:** dos páginas autocontenidas con datos de ejemplo. **No leen ni guardan nada en
la base de HANS**; el avance de una prueba queda solo en ese celular y se borra con
"Empezar la prueba de nuevo".

| Prototipo | Archivo | Dentro de HANS (con login) | Enlace privado de prueba |
|---|---|---|---|
| Repartidor (iPhone) | `prototypes/reparto.html` | `/reparto/prototipo` (repartidor y admin) | https://claude.ai/artifact/Nj227Rcf6DJPLvZFimj3jT |
| Administración | `prototypes/repartos-admin.html` | `/admin/repartos/prototipo` (admin; menú "Repartos (prueba)") | https://claude.ai/artifact/Jin4jbJ5EyoKdxxFLgDsgL |

**Cómo abrirlo en el iPhone**

- *Opción A — enlace privado:* abrir el enlace en Safari con una cuenta que tenga acceso.
  Para que lo abra otra persona (por ejemplo el repartidor), compartirlo desde el menú
  "Compartir" de la página.
- *Opción B — HANS local en la misma red Wi-Fi:* en la Mac, `bin/rails server -b 0.0.0.0`;
  en el iPhone, Safari → `http://<IP de la Mac>:3000` → ingresar con `envios@hans.com` (usuario
  de desarrollo, ver `db/seeds.rb`) → "PROBAR CÓMO VA A FUNCIONAR". Así se prueba también el
  login y el ícono en la pantalla de inicio (Compartir → "Agregar a inicio").

**Qué se puede probar (repartidor):** entrega con pago completo · entrega sin pago (foto o
excepción) · pago parcial · cobro del pedido y de lo que debía antes · otro importe con
teclado grande y el monto en letras · corrección de un importe con motivo · foto del remito
(abre la cámara) · gasto (nafta, insumos, estacionamiento, otro) y su ticket · editar o borrar
un gasto · "Plata para entregar" calculada (no editable) · terminar el reparto con revisión
de pendientes · intento de cambiar algo después de enviar · ir a la siguiente parada · volver
a cualquier parada desde la lista.

**Qué se puede probar (administración):** subir/bajar paradas · quitar una parada con
"¿quién la entrega?" · fuera del recorrido y "marcar entregado" · pedidos sin asignar ·
agregar parada manual · hoja de ruta · dar el recorrido al repartidor (desde ahí los cambios
piden motivo) · alerta de rendición no enviada (D8) · cierre con efectivo contado y
diferencia de caja (D3) · historial.

**Prueba sugerida con el repartidor (criterio de éxito de R1):** sin explicarle nada, pedirle
que entregue en Café Aurora y cobre lo del pedido, después que vaya a la siguiente parada y
anote que le pagaron solo $ 20.000. Observar dónde duda; anotar cada pregunta que haga.

**Capturas:** `docs/repartos/capturas/` (12 del repartidor en tamaño iPhone y 5 de
administración). Cada pantalla se abre directa agregando `#demo-<nombre>` a la dirección
(por ejemplo `#demo-importe`, `#demo-rendicion`).
