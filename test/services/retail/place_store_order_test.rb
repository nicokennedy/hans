require "test_helper"
require_relative "../../support/retail_helpers"
require_relative "../../support/retail_catalog_helpers"

# Etapa 3: pedidos de la tienda con reglas de entrega validadas en el servidor (fecha, zona,
# dirección) y costo de envío que sale de la zona y queda guardado en el pedido.
class Retail::PlaceStoreOrderTest < ActiveSupport::TestCase
  include RetailHelpers
  include RetailCatalogHelpers

  MON = Date.new(2026, 11, 9)
  WED = MON + 2

  setup do
    setup_retail
    RetailFulfillmentSetting.current
    @zone1 = RetailDeliveryZone.find_by!(name: "Zona 1")
    @zone3 = RetailDeliveryZone.find_by!(name: "Zona 3")
    @now = Time.zone.local(2026, 11, 9, 23, 30) # lunes 23:30 en Argentina
    @box = catalog_product("Box", price: "10.000", active: true)
    RetailCatalog::PhotoUpload.add(product: @box, files: [image_upload("pixel.png")])
  end

  def place(attributes = nil, token: "tok-#{rand(1_000_000)}", cart: { @box.id.to_s => 2 })
    base = { buyer_name: "Lucía", buyer_phone: "11 5555-0000", buyer_email: "lucia@example.com", delivery_kind: "delivery",
             delivery_date: WED.iso8601, delivery_zone_id: @zone1.id.to_s, address: "Alem 123", planned_payment_method: "transfer" }
    Retail::PlaceStoreOrder.call(attributes: base.merge(attributes || {}), cart: cart, request_token: token, now: @now)
  end

  test "envío a domicilio: guarda zona, nombre, franja y costo; total = productos + envío; nace pendiente" do
    result = place
    assert result.ok?, result.errors.inspect
    order = result.record.reload

    assert order.source_store?
    assert order.confirmation_awaiting?
    assert order.delivery?
    assert_equal WED, order.delivery_date
    assert_equal @zone1, order.delivery_zone
    assert_equal "Zona 1", order.delivery_zone_name
    assert_equal "8:30 a 13:00 hs", order.delivery_window_label
    assert_equal "Alem 123", order.address
    assert_equal 2_000_000, order.subtotal_cents
    assert_equal 500_000, order.shipping_cents
    assert_equal 2_500_000, order.total_cents
    assert_equal "Envío a domicilio", order.delivery_service_name
  end

  test "retiro: gratis, sin zona ni dirección, con el horario de retiro" do
    result = place({ delivery_kind: "pickup", delivery_zone_id: @zone3.id.to_s, address: "no se guarda" })
    assert result.ok?, result.errors.inspect
    order = result.record
    assert_equal 0, order.shipping_cents
    assert_equal 2_000_000, order.total_cents
    assert_nil order.delivery_zone
    assert_nil order.delivery_zone_name
    assert_nil order.address
    assert_equal "14:00 a 17:00 hs", order.delivery_window_label
    assert_equal "Retiro por zona Plaza del Agua", order.delivery_service_name
  end

  test "el cliente no puede fijar el costo, el total ni el nombre de la zona" do
    result = place({ shipping: "0", shipping_cents: 1, total_cents: 1, delivery_zone_name: "Gratis", delivery_window_label: "a las 9", delivery_time_note: "9:00" })
    assert result.ok?, result.errors.inspect
    order = result.record
    assert_equal 500_000, order.shipping_cents
    assert_equal 2_500_000, order.total_cents
    assert_equal "Zona 1", order.delivery_zone_name
    assert_equal "8:30 a 13:00 hs", order.delivery_window_label
    assert_nil order.delivery_time_note, "no se promete una hora exacta"
  end

  test "rechaza fechas antes de la anticipación, domingos, fechas bloqueadas y zonas inválidas sin crear nada" do
    RetailServiceClosure.create!(date: WED + 1, service: "delivery", reason: "Feriado")
    assert_no_difference ["RetailOrder.count", "RetailOrderItem.count", "StockMovement.count"] do
      assert_match "anticipación", place({ delivery_date: (MON + 1).iso8601 }).errors.first
      assert_match "domingos", place({ delivery_date: (MON + 6).iso8601 }).errors.first
      assert_match "Feriado", place({ delivery_date: (WED + 1).iso8601 }).errors.first
      assert_equal ["La fecha de entrega no es válida."], place({ delivery_date: "2026-13-01" }).errors
      assert_equal ["La zona de envío elegida no está disponible."], place({ delivery_zone_id: "0" }).errors
      @zone3.update!(active: false)
      assert_equal ["La zona de envío elegida no está disponible."], place({ delivery_zone_id: @zone3.id.to_s }).errors
      assert_equal ["Completá la dirección de entrega."], place({ address: " " }).errors
      assert_equal ["Elegí una modalidad de entrega válida."], place({ delivery_kind: "drone" }).errors
    end
  end

  test "un pedido conserva su costo y su zona aunque después cambie la tarifa o el nombre" do
    order = place.record
    @zone1.update!(price: "8.000", name: "Zona costera")

    order.reload
    assert_equal 500_000, order.shipping_cents
    assert_equal 2_500_000, order.total_cents
    assert_equal "Zona 1", order.delivery_zone_name

    newer = place.record
    assert_equal 800_000, newer.shipping_cents
    assert_equal "Zona costera", newer.delivery_zone_name
  end

  test "editar el pedido desde el admin sin tocar la entrega no recalcula el envío con la tarifa nueva" do
    order = place.record
    @zone1.update!(price: "9.000")
    rows = item_rows_for(order)
    updated = update_retail(order, attributes: { delivery_kind: "delivery", delivery_date: WED.iso8601, address: "Alem 123",
                                                 shipping: "5.000", delivery_zone_id: @zone1.id.to_s, delivery_time_note: "" }, items: rows)
    assert_equal 500_000, updated.shipping_cents
    assert_equal "Zona 1", updated.delivery_zone_name
    assert_equal "8:30 a 13:00 hs", updated.delivery_window_label
  end

  test "el mismo token devuelve el pedido ya creado (aunque la fecha ya no sea elegible)" do
    first = place(token: "checkout-1").record
    @now = Time.zone.local(2026, 11, 12, 10)
    assert_no_difference "RetailOrder.count" do
      again = place(token: "checkout-1")
      assert again.ok?
      assert again.duplicate?
      assert_equal first, again.record
    end
  end
end
