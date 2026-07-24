# README

This README would normally document whatever steps are necessary to get the
application up and running.

Things you may want to cover:

* Ruby version

* System dependencies

* Configuration

* Database creation

* Database initialization

* How to run the test suite

* Services (job queues, cache servers, search engines, etc.)

* Deployment instructions

* ...

## Environment variables

* `WHATSAPP_OBRADOR_NUMBER` — número de WhatsApp del obrador usado para armar
  los links `wa.me` de "Enviar por WhatsApp" (producción diaria y detalle de
  pedido en el admin). Se guarda **sin** `+`, espacios ni guiones (formato
  `wa.me`, ej. `5492235275412`). Si no está configurada, los botones de
  WhatsApp se ocultan automáticamente en vez de generar un link roto — la
  aplicación sigue funcionando con normalidad.

  En producción (Heroku):

  ```bash
  heroku config:set WHATSAPP_OBRADOR_NUMBER=5492235275412 --app hans
  ```

  En desarrollo, alcanza con exportar la variable antes de levantar el
  servidor (`export WHATSAPP_OBRADOR_NUMBER=5492235275412`) o agregarla a tu
  `.env` local si usás alguna gema de carga de `.env`.

  Nota: por ahora esto solo genera links manuales `wa.me` — el admin todavía
  tiene que abrir el link y apretar enviar. El envío automático real (vía una
  API de WhatsApp como Twilio o Meta Cloud API) queda para un sprint aparte,
  una vez que se elija y configure un proveedor.
