# Direcciones de clientes: exportar a Excel e importar por consola

Objetivo: completar las direcciones de entrega de los clientes mayoristas (hoy solo 1 de 54
clientes activos tiene dirección) para usarlas después en Repartos y abrirlas en Google Maps.
Es independiente de las etapas R2–R8 de Repartos. No hay seguimiento GPS en HANS.

## 1. Campos que existen hoy

Tabla `customers` (revisada en `db/schema.rb`):

| Campo | Columna | En el Excel |
|---|---|---|
| ID interno | `id` | Sí, gris, "ID cliente (NO MODIFICAR)" |
| Nombre | `name` | Sí, gris (no se importa; se usa para controlar que el ID no se haya tocado) |
| Activo / inactivo | `active` | Sí, gris ("Activo" / "Inactivo"; no se importa) |
| Dirección | `address` (texto libre, opcional) | Sí, amarilla, **se importa** |
| Teléfono | `phone` | Sí, gris (no se importa) |
| Contacto, email, condiciones de pago, notas internas | `contact_name`, `email`, `payment_terms`, `internal_notes` | **No** (no hacen falta y algunas son sensibles) |

Hasta el 18/11/2026 **no existían** piso/depto/local, localidad, provincia, código postal ni
referencias de entrega. Se agregan con la migración de la sección 2.

## 2. Migración `20261118120000_add_delivery_address_fields_to_customers` (aprobada por HANS)

| Columna | Tipo | En el Excel |
|---|---|---|
| `address_unit` | string | Piso / depto / local |
| `city` | string | Localidad |
| `province` | string | Provincia |
| `postal_code` | string | Código postal |
| `delivery_instructions` | text | Referencias de entrega |

- Solo agrega columnas opcionales, sin valores por defecto ni índices: los clientes actuales
  no cambian y en Postgres es instantáneo (no reescribe la tabla).
- `address` sigue siendo "calle y número", como hoy.
- El exportador y el importador las usan apenas existen (`Customers::AddressFields`); el
  código también funciona sin ellas (las trata como "pendientes"), así que volver a una
  versión anterior de la app no rompe nada aunque las columnas sigan en la base.
- Pendiente para más adelante: mostrarlas y editarlas en la ficha del cliente.

**Estado:** aplicada en producción el 18/11/2026 (release v109, respaldo previo b008).

**Para producción (requiere autorización de HANS):** HANS no tiene una fase de release que
migre sola, así que después del deploy:

1. `heroku pg:backups:capture --app hans`
2. `heroku run --app hans -- bin/rails db:migrate`
3. Verificar: `heroku run --app hans -- bin/rails runner 'puts Customer.column_names.grep(/city|province|postal|unit|instructions/)'`

Si hubiera que deshacerla: `heroku run --app hans -- bin/rails db:rollback STEP=1` (borra las
cinco columnas y lo que se haya cargado en ellas; restaurar el respaldo si hiciera falta).

## 3. Exportar

Administración → **Clientes** → botón **Exportar clientes** (arriba a la derecha, junto a
"Nuevo cliente"). Descarga `HANS_Clientes_Direcciones_AAAA-MM-DD.xlsx`:

- Hoja **Clientes**: una fila por cliente mayorista, activos e inactivos, ordenados por nombre.
  Encabezado inmovilizado, filtros, anchos ajustados. Columnas grises = no se tocan; columnas
  amarillas = dirección de entrega. Celdas vacías cuando no hay dato.
- Hoja **Instrucciones**: cómo completarlo.
- Solo admin. Exportar no modifica nada.

## 4. Importar (por consola)

Reglas (`Customers::AddressImport`):

- Cada fila se identifica **solo por el ID**, y el **Nombre** de la fila tiene que coincidir con
  el del cliente (sin importar mayúsculas ni tildes); si no coincide, la fila se rechaza
  (protege contra un ID modificado por error).
- No crea ni borra clientes. Nombre, estado, teléfono y cualquier otra columna se ignoran (si
  cambiaron, se avisa).
- Un valor igual al que ya tiene HANS no se valida ni se toca (así un dato viejo con otro
  formato no traba la fila).
- Solo actualiza los seis campos de dirección (los que existan en la base; si faltara alguna
  columna, ese dato se informa como "pendiente" y no se guarda). **Una celda vacía no borra
  nada.**
- Rechaza la fila entera (y lo informa) si: el ID no es un número, está repetido en el Excel,
  no existe, el nombre no coincide, o algún valor es inválido:
  - Dirección: al menos 4 caracteres, con letras y con número (o "S/N"); sin fórmulas.
  - Provincia: una provincia argentina (acepta "CABA", "Bs As", sin tildes, etc. y la guarda
    con el nombre oficial).
  - Código postal: 4 números (7600) o CPA (B7600ABC).
  - Largo máximo por campo.
- Primero **dry run** (no escribe): muestra cliente, valor anterior y valor nuevo.
- La importación real exige `CONFIRMAR=SI`, corre en **una sola transacción** (todo o nada) y
  verifica que ningún cliente haya cambiado desde la lectura. Termina con un informe; con
  `REPORT=archivo.csv` además guarda el detalle en CSV.

### En la computadora (base local)

```bash
bin/rails hans:customer_addresses:check FILE=HANS_Clientes_Direcciones.xlsx
bin/rails hans:customer_addresses:import FILE=HANS_Clientes_Direcciones.xlsx CONFIRMAR=SI REPORT=tmp/informe.csv
```

### En producción (Heroku) — solo con autorización de HANS

Requisito: que esta funcionalidad esté desplegada y la migración aplicada (sección 2). El archivo no está en el servidor, así que se
manda por la entrada estándar en base64 (`FILE=-`).

1. Respaldo de la base: `heroku pg:backups:capture --app hans`
2. Dry run, guardando la salida:
   `base64 -i HANS_Clientes_Direcciones.xlsx | heroku run --no-tty --app hans -- bin/rails hans:customer_addresses:check FILE=- | tee dry-run.txt`
3. Revisar `dry-run.txt` con HANS y **pedir autorización** para escribir.
4. Importación real, guardando el informe:
   `base64 -i HANS_Clientes_Direcciones.xlsx | heroku run --no-tty --app hans -- bin/rails hans:customer_addresses:import FILE=- CONFIRMAR=SI | tee informe-importacion.txt`
5. Exportar de nuevo desde HANS y verificar algunas direcciones.

Para deshacer: restaurar el respaldo del paso 1 o volver a importar el Excel exportado antes de
la importación (con los valores anteriores).

## 5. Uso en Repartos

`Customer#maps_query` y `Customer#google_maps_url` arman la búsqueda de Google Maps con calle y
número, localidad, provincia y código postal (los que existan) y "Argentina"; sin piso ni
referencias. Devuelven `nil` si el cliente no tiene dirección. Repartos (R3) los va a usar para
el botón "Cómo llegar"; las referencias de entrega se mostrarán como texto al repartidor.
