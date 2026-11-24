require "test_helper"
require_relative "../support/retail_helpers"
require Rails.root.join("db/migrate/20261124120000_update_retail_delivery_zones_2026")

# Migración de datos de las zonas definitivas: actualiza por nombre, crea las que faltan, deja las
# cinco habilitadas y primeras en el orden, no toca otras zonas (salvo su orden) ni los pedidos.
class UpdateRetailDeliveryZones2026Test < ActiveSupport::TestCase
  include RetailHelpers

  EXPECTED = [
    ["Zona 1", "Av. Patricio Peralta Ramos - Av. Juan B. Justo - Av. Independencia", 500_000, true, 1],
    ["Zona 2", "Av. Patricio Peralta Ramos - Av. Juan B. Justo - Av. M. Champagnat - Av. Libertad", 600_000, true, 2],
    ["Zona 3", "Av. Libertad - Av. M. Champagnat - Av. José Estrada", 700_000, true, 3],
    ["Zona 4", "Av. Mario Bravo - Av. Jacinto Peralta Ramos - Av. de los Trabajadores", 600_000, true, 4],
    ["Zona 5", "Barrios del sur", 700_000, true, 5]
  ].freeze

  setup do
    setup_retail
    RetailFulfillmentSetting.current
    # Estado anterior (producción hasta hoy): tres zonas con la cobertura vieja, una de ellas
    # desactivada y con otro precio, y una zona extra creada a mano.
    RetailDeliveryZone.where(name: ["Zona 4", "Zona 5"]).delete_all
    RetailDeliveryZone.find_by!(name: "Zona 1").update!(coverage: "Costa, Independencia, Colón, Vértiz", position: 1)
    @zone2 = RetailDeliveryZone.find_by!(name: "Zona 2")
    @zone2.update!(coverage: "Centro, zona Facultad", price: "6.500", position: 3)
    RetailDeliveryZone.find_by!(name: "Zona 3").update!(name: "ZONA 3", coverage: "Constitución", position: 4)
    @extra = RetailDeliveryZone.create!(name: "Sierra de los Padres", price: "12.000", active: false, position: 2)

    @order = Retail::SaveOrder.call(order: RetailOrder.new,
      attributes: { buyer_name: "Ana", delivery_date: next_delivery_date.iso8601, delivery_kind: "delivery", address: "Alem 1", delivery_zone_id: @zone2.id.to_s, shipping: "6.500" },
      items: [{ "kind" => "manual", "description" => "Box", "quantity" => "1", "unit_price" => "10.000" }], user: @admin).record
    assert @order.persisted?, @order.errors.full_messages.inspect
    @zone2.update!(active: false) # desactivada después de usarse
  end

  test "deja las cinco zonas definitivas, habilitadas y primeras, sin tocar pedidos ni otras zonas" do
    before = @order.reload.attributes.slice("delivery_zone_id", "delivery_zone_name", "shipping_cents", "subtotal_cents", "total_cents", "updated_at")

    migrate!

    zones = RetailDeliveryZone.ordered.to_a
    assert_equal EXPECTED, zones.first(5).map { |z| [z.name.sub("ZONA", "Zona"), z.coverage, z.price_cents, z.active?, z.position] }
    assert_equal @zone2.id, zones.second.id, "actualiza la zona existente, no crea otra"
    assert_equal "ZONA 3", zones.third.name, "el nombre existente no se cambia"

    @extra.reload
    assert_equal [6, 1_200_000, false], [@extra.position, @extra.price_cents, @extra.active?], "otras zonas solo pasan detrás"

    assert_equal before, @order.reload.attributes.slice(*before.keys), "los pedidos conservan zona, nombre y envío"
    assert_equal 650_000, @order.shipping_cents
  end

  test "es idempotente" do
    migrate!
    snapshot = RetailDeliveryZone.ordered.map { |z| z.attributes.except("updated_at") }
    assert_no_difference "RetailDeliveryZone.count" do
      migrate!
    end
    assert_equal snapshot, RetailDeliveryZone.ordered.map { |z| z.attributes.except("updated_at") }
  end

  test "el checkout ofrece las cinco zonas con sus precios" do
    migrate!
    zones = RetailFulfillment::Options.call[:zones]
    assert_equal [["Zona 1", "$5.000"], ["Zona 2", "$6.000"], ["ZONA 3", "$7.000"], ["Zona 4", "$6.000"], ["Zona 5", "$7.000"]],
      zones.map { |z| [z[:name], z[:price]] }
  end

  private

  def migrate!
    ActiveRecord::Migration.suppress_messages { UpdateRetailDeliveryZones2026.new.up }
  end
end
