require "test_helper"
require_relative "../../support/retail_helpers"
require_relative "../../support/retail_catalog_helpers"

# Etapa 4: lo que hace el servidor con un pedido de la tienda pública. Precios siempre del catálogo
# minorista, productos publicados, datos del comprador, formas de pago, ítems vinculados a
# producción, carrito en la sesión y mensaje de WhatsApp armado desde el pedido guardado.
class Retail::StoreCheckoutTest < ActiveSupport::TestCase
  include RetailHelpers
  include RetailCatalogHelpers

  MON = Date.new(2026, 11, 9)
  WED = MON + 2

  setup do
    setup_retail
    RetailFulfillmentSetting.current
    @zones = RetailDeliveryZone.ordered.to_a
    @now = Time.zone.local(2026, 11, 9, 10) # lunes en Argentina
    @shop_category = catalog_category("Tortas", active: true)
    @torta = published_product("Torta de chocolate", "20.000")
    @cookies = published_product("Cookies", "4.000")
  end

  def published_product(name, price, **attrs)
    product = catalog_product(name, category: @shop_category, price: price, active: true, **attrs)
    RetailCatalog::PhotoUpload.add(product: product, files: [image_upload("pixel.png")])
    product
  end

  def buyer(overrides = {})
    { buyer_name: "María Pérez", buyer_phone: "223 5550000", buyer_email: "maria@example.com", delivery_kind: "pickup",
      delivery_date: WED.iso8601, planned_payment_method: "transfer", notes: "" }.merge(overrides)
  end

  def place(attributes = {}, cart: { @torta.id.to_s => 1, @cookies.id.to_s => 2 }, token: "store-#{SecureRandom.hex(8)}")
    Retail::PlaceStoreOrder.call(attributes: buyer(attributes), cart: cart, request_token: token, now: @now)
  end

  test "precios del catálogo minorista: subtotal, retiro gratis, total; nace pendiente y sin pagos" do
    result = place
    assert result.ok?, result.errors.inspect
    order = result.record.reload

    assert order.source_store?
    assert order.confirmation_awaiting?
    assert order.payment_pending?
    assert_equal 0, order.amount_paid_cents
    assert_empty order.retail_order_payments
    assert_equal 2_800_000, order.subtotal_cents
    assert_equal 0, order.shipping_cents
    assert_equal 2_800_000, order.total_cents
    assert_equal "maria@example.com", order.buyer_email
    assert_equal "14:00 a 17:00 hs", order.delivery_window_label
    assert_equal [["Torta de chocolate", 1, 2_000_000], ["Cookies", 2, 400_000]],
      order.retail_order_items.map { |i| [i.display_name, i.quantity, i.unit_price_cents] }
    assert_equal [@torta.id, @cookies.id], order.retail_order_items.map(&:retail_product_id)
    assert_equal 0, StockMovement.where(retail_order: order).count, "un pedido pendiente no mueve stock"
  end

  test "envío a domicilio: cada zona cobra su precio y el total lo suma" do
    expected = { "Zona 1" => 500_000, "Zona 2" => 600_000, "Zona 3" => 700_000 }
    @zones.each do |zone|
      order = place({ delivery_kind: "delivery", delivery_zone_id: zone.id.to_s, address: "Alem 123" }).record
      assert_equal expected.fetch(zone.name), order.shipping_cents
      assert_equal 2_800_000 + expected.fetch(zone.name), order.total_cents
      assert_equal zone.name, order.delivery_zone_name
      assert_equal "8:30 a 13:00 hs", order.delivery_window_label
    end
  end

  test "ignora precios, totales, descuentos y costos que mande el navegador" do
    result = place({ shipping: "0", total_cents: 1, subtotal_cents: 1, unit_price: "1", discount: "100", price_cents: 1,
                     delivery_kind: "delivery", delivery_zone_id: @zones.first.id.to_s, address: "Alem 123" },
                   cart: { @torta.id.to_s => 1 })
    assert result.ok?, result.errors.inspect
    assert_equal 2_000_000, result.record.subtotal_cents
    assert_equal 2_500_000, result.record.total_cents
  end

  test "el carrito solo aporta ids y cantidades: un precio dentro del carrito no se usa" do
    result = place({}, cart: { @torta.id.to_s => { "quantity" => 1, "price" => 1 } })
    assert_not result.ok?
    assert_match "cantidades", result.errors.first
  end

  test "usa el precio vigente al momento del pedido" do
    @torta.update!(price: "25.000")
    order = place({}, cart: { @torta.id.to_s => 1 }).record
    assert_equal 2_500_000, order.total_cents
    @torta.update!(price: "30.000")
    assert_equal 2_500_000, order.reload.total_cents, "el pedido guarda el precio con el que se hizo"
  end

  test "rechaza productos inactivos, de categoría inactiva, sin foto o inexistentes, sin crear nada" do
    inactive = published_product("Inactivo", "1.000")
    inactive.update!(active: false)
    other_category = catalog_category("Oculta", active: false)
    hidden = catalog_product("Oculto", category: other_category, price: "1.000", active: true)
    RetailCatalog::PhotoUpload.add(product: hidden, files: [image_upload("pixel.png")])
    no_photo = catalog_product("Sin foto", category: @shop_category, price: "1.000", active: true)

    assert_no_difference ["RetailOrder.count", "RetailOrderItem.count"] do
      [inactive, hidden, no_photo].each do |product|
        result = place({}, cart: { product.id.to_s => 1 })
        assert_equal ["Algunos productos del carrito ya no están disponibles. Revisá el carrito."], result.errors
      end
      assert_equal ["Algunos productos del carrito ya no están disponibles. Revisá el carrito."], place({}, cart: { "999999999" => 1 }).errors
      assert_equal ["Tu carrito está vacío."], place({}, cart: {}).errors
    end
  end

  test "valida cantidades: enteras de 1 a 99" do
    ["0", "-1", "100", "1.5", "abc", ""].each do |quantity|
      result = place({}, cart: { @torta.id.to_s => quantity })
      assert_not result.ok?, "cantidad #{quantity.inspect}"
      assert_match "cantidades", result.errors.first
    end
    assert place({}, cart: { @torta.id.to_s => "99" }).ok?
  end

  test "datos del comprador: nombre, celular, email y forma de pago obligatorios y válidos" do
    errors = place({ buyer_name: " ", buyer_phone: "", buyer_email: "", planned_payment_method: "" }).errors
    assert_includes errors, "Completá tu nombre y apellido."
    assert_includes errors, "Completá tu celular con WhatsApp."
    assert_includes errors, "Completá tu email."
    assert_includes errors, "Elegí la forma de pago: transferencia bancaria o efectivo."

    assert_match "celular", place({ buyer_phone: "123" }).errors.first
    assert_match "email", place({ buyer_email: "maria@" }).errors.first
    %w[openpay other mercadopago].each do |method|
      assert_equal ["Elegí la forma de pago: transferencia bancaria o efectivo."], place({ planned_payment_method: method }).errors
    end
    assert_match "notas", place({ notes: "x" * 1001 }).errors.first
  end

  test "transferencia y efectivo quedan como forma de pago prevista, sin registrar pagos" do
    transfer = place({ planned_payment_method: "transfer" }).record
    cash = place({ planned_payment_method: "cash_on_delivery" }).record
    assert_equal "Transferencia bancaria", transfer.store_payment_method_label
    assert_equal "Efectivo", cash.store_payment_method_label
    [transfer, cash].each do |order|
      assert order.payment_pending?
      assert_equal 0, order.retail_order_payments.count
    end
  end

  test "fechas: dos días calendario de anticipación en Argentina, sin domingos ni fechas sin servicio" do
    late_monday = Time.utc(2026, 11, 10, 2, 30) # lunes 23:30 en Argentina (ya martes en UTC)
    assert_match "anticipación", Retail::PlaceStoreOrder.call(attributes: buyer(delivery_date: (MON + 1).iso8601), cart: { @torta.id.to_s => 1 }, request_token: "a1", now: late_monday).errors.first
    ok = Retail::PlaceStoreOrder.call(attributes: buyer(delivery_date: WED.iso8601), cart: { @torta.id.to_s => 1 }, request_token: "a2", now: late_monday)
    assert ok.ok?, ok.errors.inspect
    assert_match "domingos", place({ delivery_date: (MON + 6).iso8601 }).errors.first
    RetailServiceClosure.create!(date: WED + 1, service: "all", reason: "Inventario")
    assert_match "Inventario", place({ delivery_date: (WED + 1).iso8601 }).errors.first
  end

  test "un producto vinculado a un producto mayorista activo entra a producción como ese producto, con el nombre y precio de la tienda" do
    linked = published_product("Mini rogel x 12", "9.000", product: @mini)
    inactive_link = published_product("Torta vieja", "5.000", product: @torta_wholesale = make_product("Inactivo #{rand(1000)}", 100))
    @torta_wholesale.update!(active: false)

    order = place({}, cart: { linked.id.to_s => 2, inactive_link.id.to_s => 1 }).record
    first, second = order.retail_order_items.to_a
    assert_equal @mini, first.product
    assert_equal "Mini rogel x 12", first.display_name
    assert_equal 900_000, first.unit_price_cents
    assert second.manual?, "sin producto mayorista activo queda como producto especial"
    assert_equal "Torta vieja", second.display_name
  end

  test "idempotencia: el mismo token devuelve el mismo pedido" do
    first = place({}, token: "store-abc")
    second = place({}, token: "store-abc")
    assert first.ok?
    assert second.duplicate?
    assert_equal first.record, second.record
    assert_equal 1, RetailOrder.where(request_token: "store-abc").count
    assert_not place({}, token: " ").ok?, "sin token no se crea"
  end

  test "compatibilidad: los pedidos anteriores (sin email ni producto de la tienda) siguen válidos y editables" do
    old = create_retail
    assert_nil old.buyer_email
    assert old.retail_order_items.all? { |i| i.retail_product_id.nil? }
    updated = update_retail(old, attributes: { buyer_name: "Otro" }, items: item_rows_for(old))
    assert_equal "Otro", updated.buyer_name
    assert updated.confirmation_confirmed?
  end

  test "mensaje de WhatsApp: se arma desde el pedido guardado y va codificado a wa.me de HANS" do
    order = place({ delivery_kind: "delivery", delivery_zone_id: @zones.second.id.to_s, address: "Alem 123 & Colón",
                    notes: "Feliz cumple Ana!\nSin nueces", planned_payment_method: "cash_on_delivery" }).record
    message = Retail::StoreWhatsappMessage.new(order)
    text = message.text

    assert_includes text, "Hola HANS! 🍰 Quiero confirmar mi pedido ##{order.number}."
    assert_includes text, "• 1 × Torta de chocolate — $20.000"
    assert_includes text, "• 2 × Cookies — $8.000"
    assert_includes text, "Subtotal: $28.000"
    assert_includes text, "Envío: $6.000"
    assert_includes text, "Total: $34.000"
    assert_includes text, "Nombre: María Pérez"
    assert_includes text, "Teléfono: 223 5550000"
    assert_includes text, "Modalidad: Envío a domicilio"
    assert_includes text, "Zona: Zona 2"
    assert_includes text, "Dirección: Alem 123 & Colón"
    assert_includes text, "Fecha: miércoles 11/11"
    assert_includes text, "Horario: 8:30 a 13:00 hs"
    assert_includes text, "Forma de pago: Efectivo"
    assert_includes text, "Observaciones: Feliz cumple Ana!\nSin nueces"
    assert text.end_with?("Quedo a la espera de la confirmación. ¡Gracias!")

    url = message.url
    assert url.start_with?("https://wa.me/5492235275412?text=")
    assert_not_includes url.split("?text=").last, " "
    assert_not_includes url.split("?text=").last, "&"
    assert_equal text, URI.decode_www_form_component(url.split("?text=").last)

    pickup = Retail::StoreWhatsappMessage.new(place.record).text
    assert_includes pickup, "Modalidad: Retiro por zona Plaza del Agua"
    assert_includes pickup, "Envío: Gratis"
    assert_includes pickup, "Forma de pago: Transferencia bancaria"
    assert_not_includes pickup, "Zona:"
    assert_not_includes pickup, "Dirección:"
  end

  test "el mensaje usa los valores guardados aunque después cambien precios o zonas" do
    order = place({ delivery_kind: "delivery", delivery_zone_id: @zones.first.id.to_s, address: "Alem 123" }).record
    @torta.update!(price: "99.000")
    @zones.first.update!(price: "9.000", name: "Zona costera")
    text = Retail::StoreWhatsappMessage.new(order.reload).text
    assert_includes text, "Total: $33.000"
    assert_includes text, "Zona: Zona 1"
  end

  test "carrito en la sesión: guarda solo ids y cantidades, suma, limita y saca lo que deja de estar publicado" do
    session = {}
    cart = Retail::StoreCart.new(session)
    assert_nil cart.add(@torta.id, 2)
    assert_nil cart.add(@torta.id, "1")
    assert_nil cart.add(@cookies.id, 1)
    assert_equal({ @torta.id.to_s => 3, @cookies.id.to_s => 1 }, session[Retail::StoreCart::SESSION_KEY])
    assert_equal 4, cart.count
    assert_equal 6_400_000, cart.subtotal_cents

    # Otra petición con la misma sesión (recarga): mismo carrito.
    again = Retail::StoreCart.new(session)
    assert_equal 2, again.lines.size

    assert_equal "Elegí una cantidad de 1 a 99.", again.update(@torta.id, "0")
    assert_equal "Elegí una cantidad de 1 a 99.", again.add(@torta.id, "500")
    assert_match "hasta 99", again.add(@torta.id, 98)
    assert_equal 99, again.contents[@torta.id.to_s]
    assert_equal "Ese producto no está disponible.", again.add("999999", 1)

    @cookies.update!(active: false)
    fresh = Retail::StoreCart.new(session)
    assert_equal [@torta], fresh.lines.map(&:product)
    assert_equal ["Cookies"], fresh.dropped
    assert_not session[Retail::StoreCart::SESSION_KEY].key?(@cookies.id.to_s)

    fresh.remove(@torta.id)
    assert fresh.empty?
    assert_nil session[Retail::StoreCart::SESSION_KEY]
    assert_equal 0, StockMovement.count, "el carrito no toca stock"
  end

  test "el carrito descarta datos adulterados en la sesión" do
    session = { Retail::StoreCart::SESSION_KEY => { "abc" => 2, @torta.id.to_s => "500", @cookies.id.to_s => -3 } }
    cart = Retail::StoreCart.new(session)
    assert_equal({ @torta.id.to_s => 99 }, cart.contents)
    assert_equal({}, Retail::StoreCart.new({ Retail::StoreCart::SESSION_KEY => "basura" }).contents)
  end
end
