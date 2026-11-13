require "test_helper"
require_relative "../../support/retail_helpers"
require_relative "../../support/retail_catalog_helpers"

# Variantes de la tienda (tamaños / presentaciones) y stock de venta online: precio de catálogo del
# tamaño más grande disponible, precio por variante validado en el servidor, disponibilidad por
# variante y reservas de stock que no se duplican ni se pasan del límite.
class Retail::VariantsAndOnlineStockTest < ActiveSupport::TestCase
  include RetailHelpers
  include RetailCatalogHelpers

  MON = Date.new(2026, 11, 9)
  WED = MON + 2

  setup do
    setup_retail
    RetailFulfillmentSetting.current
    @now = Time.zone.local(2026, 11, 9, 10)
    @shop = catalog_category("Tortas #{rand(1_000_000)}", active: true)
    # Desfasa los ids de variantes respecto de los de productos para que un test no pase por casualidad.
    @filler = catalog_product("Relleno", category: @shop, active: false, variants_attributes: [{ name: "a", price: "1", position: 1 }, { name: "b", price: "1", position: 2 }, { name: "c", price: "1", position: 3 }])
    @nuez = published_product("Torta nuez", variants_attributes: [{ name: "18 cm", position: 1, price: "38.000" }, { name: "22 cm", position: 2, price: "46.000" }])
    @small, @large = @nuez.variants.to_a
    @box = published_product("Box Halloween", price: "18.000")
    @box_variant = @box.variants.first
  end

  def published_product(name, **attrs)
    product = catalog_product(name, category: @shop, active: true, **attrs)
    RetailCatalog::PhotoUpload.add(product: product, files: [image_upload("pixel.png")])
    product.reload
  end

  def buyer
    { buyer_name: "María Pérez", buyer_phone: "223 5550000", buyer_email: "maria@example.com", delivery_kind: "pickup",
      delivery_date: WED.iso8601, planned_payment_method: "transfer", notes: "" }
  end

  def place(cart, token: "store-#{SecureRandom.hex(8)}")
    Retail::PlaceStoreOrder.call(attributes: buyer, cart: cart.transform_keys { |k| k.id.to_s }, request_token: token, now: @now)
  end

  def limit!(variant, units)
    variant.update!(stock_quantity: units)
    variant
  end

  # --- Variantes y precio ---------------------------------------------------------------------------

  test "un producto, dos tamaños: el catálogo muestra el precio del más grande disponible" do
    assert_equal [@small.id, @large.id].sort, @nuez.variants.map(&:id).sort
    assert @small.id != @nuez.id || @large.id != @nuez.id
    assert_equal 4_600_000, @nuez.price_cents
    assert_equal @large, @nuez.display_variant

    @large.update!(active: false)
    assert_equal @small, @nuez.reload.display_variant, "sin el grande, se muestra el de 18 cm"
    assert_equal 3_800_000, @nuez.reload.tap(&:save!).price_cents

    @large.update!(active: true, stock_quantity: 0)
    assert_equal @small, @nuez.reload.display_variant, "el grande agotado no define el precio"
  end

  test "el pedido toma el precio y el nombre de la variante elegida, nunca del navegador" do
    result = Retail::PlaceStoreOrder.call(attributes: buyer, cart: { @small.id.to_s => 2 }, request_token: "store-a", now: @now)
    assert result.ok?, result.errors.inspect
    item = result.record.retail_order_items.first
    assert_equal [@small.id, @nuez.id, "18 cm", "Torta nuez · 18 cm", 3_800_000, 2], [item.retail_product_variant_id, item.retail_product_id, item.variant_name_snapshot, item.display_name, item.unit_price_cents, item.quantity]
    assert_equal 7_600_000, result.record.subtotal_cents

    forged = Retail::PlaceStoreOrder.call(attributes: buyer, cart: { @large.id.to_s => { "quantity" => 1, "price" => 1 } }, request_token: "store-b", now: @now)
    assert_not forged.ok?
    assert_includes Retail::StoreWhatsappMessage.new(result.record).text, "2 × Torta nuez · 18 cm"
  end

  test "variante deshabilitada, producto oculto o id de producto en vez de variante: no se compra" do
    @small.update!(active: false)
    assert_not place({ @small => 1 }).ok?

    @nuez.update!(active: false)
    assert_not place({ @large => 1 }).ok?, "producto oculto: tampoco por enlace o carrito viejo"
    assert_not RetailProduct.for_store.exists?(@nuez.id)

    @nuez.update!(active: true)
    @nuez.variants.each { |v| v.update!(active: false) }
    assert_not RetailProduct.for_store.exists?(@nuez.id), "sin variantes habilitadas no se publica"
  end

  # --- Stock online ---------------------------------------------------------------------------------

  test "stock limitado: no se vende más de lo cargado y en cero queda agotado" do
    limit!(@box_variant, 20)
    assert place({ @box_variant => 15 }).ok?
    assert_equal 5, @box_variant.reload.stock_quantity

    over = place({ @box_variant => 6 })
    assert_not over.ok?
    assert_match "quedan 5 unidades", over.errors.join

    assert place({ @box_variant => 5 }).ok?
    assert_equal 0, @box_variant.reload.stock_quantity
    assert @box.reload.sold_out?
    assert_not @box.purchasable?
    assert_match "agotado", place({ @box_variant => 1 }).errors.join
    assert_equal "Ese producto no está disponible.", Retail::StoreCart.new({}).add(@box_variant.id, 1)
  end

  test "sin límite no se representa con un número y no descuenta nada" do
    assert_nil @box_variant.stock_quantity
    order = place({ @box_variant => 50 }).record
    assert_nil @box_variant.reload.stock_quantity
    assert_equal 0, order.retail_order_items.first.online_stock_reserved
  end

  test "pendiente reserva; cancelado y rechazado devuelven; los cambios repetidos no descuentan dos veces" do
    limit!(@box_variant, 10)
    first = place({ @box_variant => 3 }).record
    second = place({ @box_variant => 4 }).record
    assert first.confirmation_awaiting?
    assert_equal 3, @box_variant.reload.stock_quantity, "pendientes de confirmación ya reservan"

    Retail::ChangeConfirmation.call(order: first, action: "confirm", user: @admin)
    assert_equal 3, @box_variant.reload.stock_quantity, "confirmar no vuelve a descontar"

    assert Retail::ChangeStatus.call(order: first, to_status: "canceled", user: @admin).ok?
    assert_equal 6, @box_variant.reload.stock_quantity
    assert_not Retail::ChangeStatus.call(order: first, to_status: "canceled", user: @admin).ok?
    Retail::OnlineStock.reconcile!(first.reload)
    Retail::OnlineStock.reconcile!(first.reload)
    assert_equal 6, @box_variant.reload.stock_quantity, "reconciliar de nuevo no devuelve dos veces"

    Retail::ChangeConfirmation.call(order: second, action: "reject", user: @admin, reason: "Sin stock")
    assert_equal 10, @box_variant.reload.stock_quantity
    assert_equal [0, 0], [first, second].map { |o| o.retail_order_items.first.reload.online_stock_reserved }
  end

  test "reactivar un pedido cancelado vuelve a reservar, o falla sin cambiar nada si ya no alcanza" do
    limit!(@box_variant, 5)
    order = place({ @box_variant => 4 }).record
    Retail::ChangeConfirmation.call(order: order, action: "confirm", user: @admin)
    Retail::ChangeStatus.call(order: order, to_status: "canceled", user: @admin)
    place({ @box_variant => 3 })
    assert_equal 2, @box_variant.reload.stock_quantity

    result = Retail::ChangeStatus.call(order: order, to_status: "pending", user: @admin)
    assert_not result.ok?
    assert_match "quedan 2", result.errors.join
    assert order.reload.canceled?, "no cambió el estado"
    assert_equal 2, @box_variant.reload.stock_quantity
  end

  test "reintento con el mismo token: un solo pedido y una sola reserva" do
    limit!(@box_variant, 5)
    a = place({ @box_variant => 2 }, token: "store-same")
    b = place({ @box_variant => 2 }, token: "store-same")
    assert b.duplicate?
    assert_equal a.record, b.record
    assert_equal 3, @box_variant.reload.stock_quantity
  end

  test "editar la cantidad descuenta o devuelve la diferencia; quitar la línea devuelve todo" do
    limit!(@box_variant, 10)
    order = place({ @box_variant => 2, @small => 1 }).record
    assert_equal 8, @box_variant.reload.stock_quantity
    rows = item_rows_for(order)
    rows.find { |r| r["description"].start_with?("Box") }["quantity"] = "5"
    update_retail(order, attributes: { delivery_date: WED.iso8601, buyer_email: "maria@example.com" }, items: rows)
    assert_equal 5, @box_variant.reload.stock_quantity

    too_many = rows.map(&:dup)
    too_many.find { |r| r["description"].start_with?("Box") }["quantity"] = "50"
    result = Retail::SaveOrder.call(order: order, attributes: base_attributes(delivery_date: WED.iso8601), items: too_many, user: @admin)
    assert_not result.ok?
    assert_equal 5, @box_variant.reload.stock_quantity, "si no alcanza no se guarda nada"

    without_box = rows.reject { |r| r["description"].start_with?("Box") }
    update_retail(order, attributes: { delivery_date: WED.iso8601 }, items: without_box)
    assert_equal 10, @box_variant.reload.stock_quantity
  end

  test "el stock online no toca el stock de producción ni mayorista" do
    limit!(@box_variant, 10)
    before = [StockMovement.count, StockItem.order(:id).pluck(:id, :quantity)]
    order = place({ @box_variant => 2 }).record
    Retail::ChangeStatus.call(order: order, to_status: "canceled", user: @admin)
    assert_equal before, [StockMovement.count, StockItem.order(:id).pluck(:id, :quantity)]
  end

  test "pasar de sin límite a limitado no descuenta pedidos anteriores; volver a sin límite libera sin sumar" do
    order = place({ @box_variant => 2 }).record
    limit!(@box_variant, 7)
    Retail::ChangeStatus.call(order: order, to_status: "canceled", user: @admin)
    assert_equal 7, @box_variant.reload.stock_quantity

    other = place({ @box_variant => 3 }).record
    assert_equal 4, @box_variant.reload.stock_quantity
    @box_variant.update!(stock_quantity: nil)
    Retail::ChangeStatus.call(order: other, to_status: "canceled", user: @admin)
    assert_nil @box_variant.reload.stock_quantity
    assert_equal 0, other.retail_order_items.first.reload.online_stock_reserved
  end

  test "stock: no acepta negativos ni un número pisado mientras el formulario estaba abierto" do
    assert_not @box_variant.update(stock_quantity: -1)
    limit!(@box_variant, 5)
    place({ @box_variant => 2 })
    stale = RetailProductVariant.find(@box_variant.id)
    stale.stock_quantity_seen = "5"
    stale.stock_mode = "limited"
    stale.stock_input = "8"
    assert_not stale.save
    assert_match "cambió mientras editabas", stale.errors.full_messages.join
    assert_raises(ActiveRecord::StatementInvalid) { @box_variant.update_columns(stock_quantity: -1) }
  end
end
