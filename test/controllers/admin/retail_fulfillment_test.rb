require "test_helper"
require_relative "../../support/retail_helpers"

# Tienda Minorista → Entregas desde el administrador (reglas, días y franjas, zonas, fechas sin
# servicio, simulador), la zona en el formulario de pedidos minoristas y los permisos.
class Admin::RetailFulfillmentTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include RetailHelpers

  setup do
    setup_retail
    n = rand(1_000_000)
    @cook = User.create!(email: "fulfillment-cook-#{n}@example.com", password: "password123", role: "production")
    @customer_user = User.create!(email: "fulfillment-cust-#{n}@example.com", password: "password123", role: "customer", customer: @customer)
    RetailFulfillmentSetting.current
    @zone1 = RetailDeliveryZone.find_by!(name: "Zona 1")
    @zone2 = RetailDeliveryZone.find_by!(name: "Zona 2")
    sign_in @admin
  end

  def schedule_params(overrides = {})
    rows = {}
    RetailServiceWindow.all.each do |w|
      rows[w.service] ||= {}
      rows[w.service][w.wday.to_s] = { enabled: w.enabled? ? "1" : "0", opens_at: w.opens_at&.rjust(5, "0"), closes_at: w.closes_at&.rjust(5, "0") }.compact
    end
    overrides.each { |(service, wday), row| rows[service][wday.to_s] = row }
    { windows: rows }
  end

  test "la pantalla muestra la configuración inicial y lo que vería un cliente" do
    get admin_retail_catalog_fulfillment_path
    assert_response :success
    assert_select "#retail-catalog-nav a.btn-dark", text: "Entregas"
    assert_select "#horarios-pickup h3", text: /Retiro por zona Plaza del Agua/
    assert_select "#horarios-delivery h3", text: /Envío a domicilio/
    assert_select "#window-pickup-1-opens[value=?]", "14:00"
    assert_select "#window-pickup-6-closes[value=?]", "13:00"
    assert_select "#window-delivery-3-opens[value=?]", "08:30"
    assert_select "#window-pickup-0-enabled[checked]", count: 0
    assert_select "#window-delivery-0-enabled[checked]", count: 0
    assert_select ".retail-zone-price", text: "$5.000"
    assert_select ".retail-zone-price", text: "$7.000"
    assert_select "#pickup-point-missing"
    assert_select "#earliest-date"
  end

  test "reglas generales: anticipación y punto de retiro" do
    patch general_admin_retail_catalog_fulfillment_path, params: { retail_fulfillment_setting: { min_lead_days: "3", pickup_point_details: "  Av. ejemplo, timbre B  " } }
    assert_redirected_to admin_retail_catalog_fulfillment_path
    assert_equal 3, RetailFulfillmentSetting.current.min_lead_days
    assert_equal "Av. ejemplo, timbre B", RetailFulfillmentSetting.current.pickup_point_details

    patch general_admin_retail_catalog_fulfillment_path, params: { retail_fulfillment_setting: { min_lead_days: "-1" } }
    assert_response :unprocessable_entity
    assert_equal 3, RetailFulfillmentSetting.current.reload.min_lead_days
  end

  test "días y horarios: se guardan todos juntos; si uno es inválido no cambia ninguno" do
    patch schedule_admin_retail_catalog_fulfillment_path, params: schedule_params(
      ["pickup", 6] => { enabled: "1", opens_at: "10:30", closes_at: "12:00" },
      ["delivery", 6] => { enabled: "0", opens_at: "08:30", closes_at: "13:00" }
    )
    assert_redirected_to admin_retail_catalog_fulfillment_path(anchor: "horarios")
    assert_equal "10:30 a 12:00 hs", RetailServiceWindow.find_by!(service: "pickup", wday: 6).label
    assert_not RetailServiceWindow.find_by!(service: "delivery", wday: 6).enabled?

    patch schedule_admin_retail_catalog_fulfillment_path, params: schedule_params(
      ["pickup", 1] => { enabled: "1", opens_at: "15:00", closes_at: "16:00" },
      ["delivery", 2] => { enabled: "1", opens_at: "13:00", closes_at: "09:00" }
    )
    assert_response :unprocessable_entity
    assert_select "#form-errors", text: /Martes: el horario de fin tiene que ser posterior/
    assert_equal "14:00 a 17:00 hs", RetailServiceWindow.find_by!(service: "pickup", wday: 1).label, "no se guardó nada"

    patch schedule_admin_retail_catalog_fulfillment_path, params: schedule_params(["pickup", 0] => { enabled: "1", opens_at: "", closes_at: "" })
    assert_response :unprocessable_entity
    assert_not RetailServiceWindow.find_by!(service: "pickup", wday: 0).reload.enabled?
  end

  test "zonas: crear, cambiar precio sin tocar pedidos anteriores, desactivar y no borrar una zona usada" do
    order = Retail::SaveOrder.call(order: RetailOrder.new, attributes: base_attributes(delivery_kind: "delivery", address: "Alem 1", delivery_zone_id: @zone1.id.to_s),
                                   items: [manual_row("Box", 1, "10.000")], user: @admin).record
    assert_equal 500_000, order.shipping_cents

    assert_difference "RetailDeliveryZone.count", 1 do
      post admin_retail_catalog_delivery_zones_path, params: { retail_delivery_zone: { name: "Zona 4", coverage: "Sierra", price: "9.000", active: "1" } }
    end
    assert_equal 900_000, RetailDeliveryZone.find_by!(name: "Zona 4").price_cents

    post admin_retail_catalog_delivery_zones_path, params: { retail_delivery_zone: { name: "zona 1", price: "1" } }
    assert_response :unprocessable_entity
    post admin_retail_catalog_delivery_zones_path, params: { retail_delivery_zone: { name: "Zona 5", price: "-10" } }
    assert_response :unprocessable_entity

    patch admin_retail_catalog_delivery_zone_path(@zone1), params: { retail_delivery_zone: { price: "5.800" } }
    assert_equal 580_000, @zone1.reload.price_cents
    order.reload
    assert_equal [500_000, 1_500_000, "Zona 1"], [order.shipping_cents, order.total_cents, order.delivery_zone_name]

    assert_no_difference "RetailDeliveryZone.count" do
      delete admin_retail_catalog_delivery_zone_path(@zone1)
    end
    assert_match "hay pedidos con esa zona", flash[:alert]

    patch toggle_active_admin_retail_catalog_delivery_zone_path(@zone1)
    assert_not @zone1.reload.active?

    assert_difference "RetailDeliveryZone.count", -1 do
      delete admin_retail_catalog_delivery_zone_path(@zone2)
    end
  end

  test "fechas sin servicio: bloquear y quitar, sin tocar el calendario mayorista" do
    date = Date.current + 10
    assert_no_difference "BlockedDate.count" do
      post admin_retail_catalog_service_closures_path, params: { retail_service_closure: { date: date.iso8601, service: "pickup", reason: "Feriado" } }
    end
    closure = RetailServiceClosure.find_by!(date: date)
    assert_equal ["pickup", "Feriado", @admin], [closure.service, closure.reason, closure.created_by]

    post admin_retail_catalog_service_closures_path, params: { retail_service_closure: { date: date.iso8601, service: "pickup" } }
    assert_match "ya está bloqueada", flash[:alert]
    post admin_retail_catalog_service_closures_path, params: { retail_service_closure: { date: date.iso8601, service: "cualquiera" } }
    assert_equal 1, RetailServiceClosure.count

    get admin_retail_catalog_fulfillment_path
    assert_select "##{ActionView::RecordIdentifier.dom_id(closure)}", text: /Feriado/

    delete admin_retail_catalog_service_closure_path(closure)
    assert_not RetailServiceClosure.exists?(closure.id)
  end

  test "simulador: calcula envío y total con la misma validación del checkout" do
    travel_to Time.zone.local(2026, 11, 9, 10) do
      get admin_retail_catalog_fulfillment_path, params: { preview: { service: "delivery", date: "2026-11-11", zone_id: @zone2.id, subtotal: "20.000" } }
      assert_select "#preview-shipping", text: "$6.000"
      assert_select "#preview-total", text: "$26.000"

      get admin_retail_catalog_fulfillment_path, params: { preview: { service: "pickup", date: "2026-11-11", subtotal: "20.000" } }
      assert_select "#preview-shipping", text: "$0 — Gratis"
      assert_select "#preview-total", text: "$20.000"

      get admin_retail_catalog_fulfillment_path, params: { preview: { service: "pickup", date: "2026-11-10" } }
      assert_select "#preview-result .alert-danger", text: /anticipación/
    end
  end

  test "solo administradores: producción, clientes y visitantes no entran a ninguna acción" do
    requests = [
      -> { get admin_retail_catalog_fulfillment_path },
      -> { patch general_admin_retail_catalog_fulfillment_path, params: { retail_fulfillment_setting: { min_lead_days: "0" } } },
      -> { patch schedule_admin_retail_catalog_fulfillment_path, params: schedule_params(["pickup", 0] => { enabled: "1", opens_at: "09:00", closes_at: "10:00" }) },
      -> { get new_admin_retail_catalog_delivery_zone_path },
      -> { post admin_retail_catalog_delivery_zones_path, params: { retail_delivery_zone: { name: "Hack", price: "0" } } },
      -> { patch admin_retail_catalog_delivery_zone_path(@zone1), params: { retail_delivery_zone: { price: "0" } } },
      -> { patch toggle_active_admin_retail_catalog_delivery_zone_path(@zone1) },
      -> { delete admin_retail_catalog_delivery_zone_path(@zone2) },
      -> { post admin_retail_catalog_service_closures_path, params: { retail_service_closure: { date: Date.current.iso8601, service: "all" } } }
    ]

    [@cook, @customer_user, nil].each do |user|
      sign_out :user
      sign_in user if user
      requests.each do |request|
        request.call
        assert_response :redirect
        assert_not_equal admin_retail_catalog_fulfillment_path, URI(response.location).path
      end
    end

    assert_equal 2, RetailFulfillmentSetting.current.min_lead_days
    assert_not RetailServiceWindow.find_by!(service: "pickup", wday: 0).enabled?
    assert_equal [500_000, true], [@zone1.reload.price_cents, @zone1.active?]
    assert RetailDeliveryZone.exists?(@zone2.id)
    assert_not RetailDeliveryZone.exists?(name: "Hack")
    assert_equal 0, RetailServiceClosure.count
  end

  # --- Pedidos minoristas cargados por el equipo ---

  test "pedido manual: elegir zona completa el envío con su precio; el equipo puede cambiar el importe (pedido especial)" do
    get new_admin_retail_order_path
    assert_select "select#delivery_zone_id option[data-price=?]", "5.000", text: /Zona 1/

    post admin_retail_orders_path, params: base_attributes(delivery_kind: "delivery", address: "Alem 1", delivery_zone_id: @zone2.id, shipping: "")
      .merge(items: { "0" => manual_row("Box", 1, "10.000") })
    order = RetailOrder.order(:id).last
    assert_equal [600_000, 1_600_000, "Zona 2"], [order.shipping_cents, order.total_cents, order.delivery_zone_name]
    assert order.confirmation_confirmed?, "los pedidos del equipo siguen naciendo confirmados"

    get admin_retail_order_path(order)
    assert_select "#retail-order-zone", text: "Zona 2"

    special = Retail::SaveOrder.call(order: RetailOrder.new, attributes: base_attributes(delivery_kind: "delivery", delivery_zone_id: @zone2.id.to_s, shipping: "0", delivery_date: @sunday.iso8601),
                                     items: [manual_row("Box", 1, "10.000")], user: @admin)
    assert special.ok?, "el equipo puede cargar cualquier fecha y otro costo: #{special.errors.inspect}"
    assert_equal 0, special.record.shipping_cents
  end

  test "pedido manual: zona inexistente o desactivada se rechaza; con retiro no queda zona" do
    @zone2.update!(active: false)
    bad = Retail::SaveOrder.call(order: RetailOrder.new, attributes: base_attributes(delivery_kind: "delivery", delivery_zone_id: @zone2.id.to_s),
                                 items: [manual_row("Box", 1, "1")], user: @admin)
    assert_equal ["La zona de envío \"Zona 2\" está desactivada."], bad.errors
    missing = Retail::SaveOrder.call(order: RetailOrder.new, attributes: base_attributes(delivery_kind: "delivery", delivery_zone_id: "0"),
                                     items: [manual_row("Box", 1, "1")], user: @admin)
    assert_equal ["La zona de envío elegida no existe."], missing.errors

    pickup = Retail::SaveOrder.call(order: RetailOrder.new, attributes: base_attributes(delivery_kind: "pickup", delivery_zone_id: @zone1.id.to_s),
                                    items: [manual_row("Box", 1, "1")], user: @admin).record
    assert_nil pickup.delivery_zone
    assert_nil pickup.delivery_zone_name
  end

  test "una zona desactivada que ya tenía el pedido se conserva al editarlo" do
    order = create_retail(attributes: { delivery_kind: "delivery", address: "Alem 1", delivery_zone_id: @zone1.id.to_s }, items: [manual_row("Box", 1, "10.000")])
    @zone1.update!(active: false, name: "Zona 1 (vieja)")

    get edit_admin_retail_order_path(order)
    assert_select "select#delivery_zone_id option[selected]", text: /Zona 1 \(vieja\).*desactivada/

    updated = update_retail(order, attributes: { delivery_kind: "delivery", address: "Alem 2", shipping: "5.000", delivery_zone_id: @zone1.id.to_s }, items: item_rows_for(order))
    assert_equal [@zone1, "Zona 1", 500_000, "Alem 2"], [updated.delivery_zone, updated.delivery_zone_name, updated.shipping_cents, updated.address]
  end

  test "los pedidos existentes sin zona se ven y se editan igual que antes" do
    legacy = create_retail(attributes: { delivery_kind: "delivery", address: "Calle 9", shipping: "3.500" }, items: [manual_row("Box", 1, "10.000")])
    legacy.update_columns(delivery_zone_id: nil, delivery_zone_name: nil, delivery_window_label: nil)

    get admin_retail_order_path(legacy)
    assert_response :success
    assert_select "#retail-order-zone", count: 0
    assert_select "#retail-order-window", count: 0

    patch admin_retail_order_path(legacy), params: base_attributes(delivery_kind: "delivery", address: "Calle 9", shipping: "3.500", delivery_zone_id: "", notes: "Tocar timbre")
      .merge(items: item_rows_for(legacy).each_with_index.to_h { |row, i| [i.to_s, row] })
    legacy.reload
    assert_equal [350_000, 1_350_000, nil, nil, "Tocar timbre"], [legacy.shipping_cents, legacy.total_cents, legacy.delivery_zone_id, legacy.delivery_window_label, legacy.notes]
  end
end
