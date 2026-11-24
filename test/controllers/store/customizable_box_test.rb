require "test_helper"
require_relative "../../support/retail_helpers"
require_relative "../../support/retail_catalog_helpers"
require_relative "../../support/box_helpers"

# Tienda: cajas con contenido personalizable (Etapa 2). Selector de sabores, carrito con
# composiciones, edición desde el carrito, checkout, pedido, WhatsApp y validaciones del servidor.
class Store::CustomizableBoxTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include RetailHelpers
  include RetailCatalogHelpers
  include BoxHelpers

  MON = Time.zone.local(2026, 11, 9, 10)
  WED = Date.new(2026, 11, 11)

  setup do
    travel_to MON
    Retail::StoreThrottle.reset!
    setup_retail
    RetailFulfillmentSetting.current
    RetailStoreSetting.current.update!(published: true, published_at: Time.current)
    @mix = create_mix_box
    @x8, @x12, @x24 = [8, 12, 24].map { |units| box_variant(@mix, units) }
  end

  teardown { travel_back }

  def add_box(variant, quantities, quantity: 1)
    post add_store_cart_path, params: { variant_id: variant.id, quantity: quantity, flavors: flavor_params(@mix, quantities) }
  end

  def cart
    session[Retail::StoreCart::SESSION_KEY] || {}
  end

  def checkout!
    get store_checkout_path
    token = css_select("input[name=checkout_token]").first["value"]
    post store_checkout_path, params: { checkout_token: token, buyer_name: "María Pérez", buyer_phone: "223 5550000", buyer_email: "maria@example.com",
                                        delivery_kind: "pickup", pickup_date: WED.iso8601, planned_payment_method: "transfer", notes: "" }
  end

  test "catálogo: 'Armar caja' lleva al detalle; el detalle muestra sabores, contador y presentaciones con sus unidades" do
    get store_root_path
    assert_select "#store_retail_product_#{@mix.id} a.store-card-quick", text: /Armar caja/
    assert_select "#store_retail_product_#{@mix.id} input[name=variant_id]", count: 0

    get store_product_path(id: @mix.id)
    assert_response :success
    assert_select "form#store-add-form[data-controller=store-box][data-store-box-units-value='24']"
    assert_select "input[name=variant_id][data-units='8']"
    assert_select "input[name=variant_id][data-units='24'][checked]"
    assert_select "#store-box .store-box-flavor", 3
    assert_select "#store-box input[type=hidden][name='flavors[#{flavor(@mix, 'Almendra').id}]'][value='0']"
    assert_select "#store-box-counter", "0 de 24 · faltan 24"
    assert_select "#store-box .store-box-fill", text: "Las 24"
    assert_select "label[for=quantity]", "Cantidad de cajas"
  end

  test "agregar: suma exacta, toda de un sabor; distintas composiciones son líneas separadas y las iguales se suman" do
    add_box(@x24, { "Almendra" => 24 })
    assert_redirected_to store_cart_path
    add_box(@x24, { "Almendra" => 12, "Maicena" => 12 })
    add_box(@x24, { "Maicena" => 12, "Almendra" => 12 }, quantity: 2)
    assert_equal 2, cart.size
    assert_equal [1, 3], cart.values

    get store_cart_path
    assert_select ".store-line", 2
    assert_select ".store-line-flavors", 2
    assert_select ".store-line-flavors li", text: /Almendra\s*× 24/
    assert_select ".store-line-flavors li", text: /Maicena\s*× 12/
    assert_select "a.store-line-edit", 2
    assert_select "#store-cart-subtotal", "$80.000"
  end

  test "el servidor rechaza cajas incompletas, excedidas, vacías, con negativos o sabores ajenos" do
    other = create_mix_box
    [
      [{ flavor(@mix, "Almendra").id.to_s => "23" }, "faltan 1"],
      [{ flavor(@mix, "Almendra").id.to_s => "20", flavor(@mix, "Cacao").id.to_s => "5" }, "sobran 1"],
      [{}, "Elegí los sabores"],
      [{ flavor(@mix, "Almendra").id.to_s => "-1", flavor(@mix, "Cacao").id.to_s => "25" }, "números enteros de 0 o más"],
      [{ flavor(@mix, "Almendra").id.to_s => "12", flavor(other, "Cacao").id.to_s => "12" }, "no corresponde a este producto"],
      [{ flavor(@mix, "Almendra").id.to_s => "24.0" }, "números enteros"]
    ].each do |flavors, message|
      post add_store_cart_path, params: { variant_id: @x24.id, quantity: 1, flavors: flavors }, headers: { "HTTP_REFERER" => store_product_path(id: @mix.id) }
      assert_redirected_to store_product_path(id: @mix.id)
      assert_match message, flash[:alert], flavors.inspect
      assert_empty cart
    end

    post add_store_cart_path, params: { product_id: @mix.id, quantity: 1 }
    assert_empty cart, "sin elegir la presentación ni los sabores no se agrega"
  end

  test "cambiar sabores desde el carrito: precarga la caja y la reemplaza conservando la cantidad" do
    add_box(@x24, { "Almendra" => 24 }, quantity: 2)
    key = cart.keys.first
    get store_cart_path
    assert_select "a.store-line-edit[href=?]", store_product_path(id: "#{@mix.id}-#{@mix.name.parameterize}", editar: key)

    get store_product_path(id: @mix.id, editar: key)
    assert_select "#store-box-editing"
    assert_select "form#store-add-form[action=?]", replace_item_store_cart_path
    assert_select "input[name=line][value=?]", key
    assert_select "input[name='flavors[#{flavor(@mix, 'Almendra').id}]'][value='24']"
    assert_select "input[name=quantity]", count: 0

    patch replace_item_store_cart_path, params: { line: key, variant_id: @x12.id, flavors: flavor_params(@mix, { "Cacao" => 6, "Maicena" => 6 }) }
    assert_redirected_to store_cart_path
    assert_equal 1, cart.size
    new_key, quantity = cart.first
    assert_equal 2, quantity
    assert_equal [@x12.id, { flavor(@mix, "Maicena").id => 6, flavor(@mix, "Cacao").id => 6 }], Retail::BoxComposition.parse_key(new_key)

    patch replace_item_store_cart_path, params: { line: new_key, variant_id: @x12.id, flavors: flavor_params(@mix, { "Cacao" => 6 }) }
    assert_match "faltan 6", flash[:alert]
    assert_equal({ new_key => 2 }, cart, "una edición inválida no toca la caja")
  end

  test "checkout y pedido: guarda una copia de la composición que no cambia al editar los sabores" do
    add_box(@x24, { "Almendra" => 12, "Maicena" => 6, "Cacao" => 6 })
    add_box(@x8, { "Cacao" => 8 }, quantity: 2)
    get store_checkout_path
    assert_select ".store-summary-name .store-composition", 2
    assert_select ".store-summary-name .store-composition li", text: /Almendra\s*× 12/

    assert_difference "RetailOrder.count", 1 do
      checkout!
    end
    order = RetailOrder.order(:id).last
    big, small = order.retail_order_items.order(:position).to_a
    assert_equal({ "units" => 24, "flavors" => [
      { "id" => flavor(@mix, "Almendra").id, "name" => "Almendra", "quantity" => 12 },
      { "id" => flavor(@mix, "Maicena").id, "name" => "Maicena", "quantity" => 6 },
      { "id" => flavor(@mix, "Cacao").id, "name" => "Cacao", "quantity" => 6 }
    ] }, big.composition)
    assert_equal [@x24.id, 1, 2_000_000], [big.retail_product_variant_id, big.quantity, big.unit_price_cents]
    assert_equal ["Cacao × 8", 2], [small.composition_text, small.quantity]
    assert big.manual?, "las cajas sin vínculo mayorista entran como producto especial"

    message = Retail::StoreWhatsappMessage.new(order).text
    assert_includes message, "• 1 × #{@mix.name} · Caja x 24 — $20.000\n   - Almendra × 12\n   - Maicena × 6\n   - Cacao × 6"
    assert_includes message, "• 2 × #{@mix.name} · Caja x 8 — $16.000\n   Cada caja:\n   - Cacao × 8"

    # Cambios posteriores en el catálogo no tocan el pedido.
    flavor(@mix, "Almendra").update!(name: "Almendra glaseada", active: false)
    @x24.update!(content_units: 20)
    get store_order_path(order.public_token)
    assert_select "#store-order-items .store-composition li", text: /Almendra\s*× 12/
    assert_equal "Almendra × 12, Maicena × 6, Cacao × 6", big.reload.composition_text

    sign_in @admin
    get admin_retail_order_path(order)
    assert_select "#retail-items .retail-item-composition", text: /Almendra × 12, Maicena × 6, Cacao × 6/
    assert_select "#retail-items .retail-item-composition", text: /Cada caja:\s*Cacao × 8/
  end

  test "un sabor que deja de estar disponible: la caja queda marcada y no se puede finalizar hasta corregirla" do
    add_box(@x24, { "Almendra" => 12, "Cacao" => 12 })
    flavor(@mix, "Cacao").update!(active: false)

    get store_cart_path
    assert_select ".store-line.has-problem .store-line-problem", /“Cacao” ya no está disponible/
    assert_select "a.store-line-edit", "Corregir sabores"
    assert_select "#store-cart-problems"
    assert_select "span#store-go-checkout[aria-disabled=true]"

    get store_checkout_path
    assert_redirected_to store_cart_path
    assert_match "Corregilas antes de finalizar", flash[:alert]

    assert_no_difference "RetailOrder.count" do
      post store_checkout_path, params: { checkout_token: "x", buyer_name: "Ana" }
    end
    assert_redirected_to store_cart_path

    # Servidor: aunque el carrito llegue igual, el pedido no se crea.
    result = Retail::PlaceStoreOrder.call(attributes: { buyer_name: "Ana", buyer_phone: "223 5550000", buyer_email: "a@example.com", delivery_kind: "pickup",
                                                        delivery_date: WED.iso8601, planned_payment_method: "cash_on_delivery" },
                                          cart: cart, request_token: "store-test-#{rand(1_000_000)}", now: MON)
    assert_not result.ok?
    assert_match "“Cacao” ya no está disponible", result.errors.join

    key = cart.keys.first
    patch replace_item_store_cart_path, params: { line: key, variant_id: @x24.id, flavors: flavor_params(@mix, { "Almendra" => 12, "Maicena" => 12 }) }
    get store_cart_path
    assert_select ".has-problem", 0
    assert_select "a#store-go-checkout"
  end

  test "carrito manipulado: cajas sin sabores o de un producto que no las permite se rechazan en el servidor" do
    base = { buyer_name: "Ana", buyer_phone: "223 5550000", buyer_email: "a@example.com", delivery_kind: "pickup", delivery_date: WED.iso8601, planned_payment_method: "transfer" }
    place = ->(cart) { Retail::PlaceStoreOrder.call(attributes: base, cart: cart, request_token: "store-t-#{rand(1_000_000)}", now: MON) }

    assert_match "Elegí los sabores", place.call({ @x24.id.to_s => 1 }).errors.join
    almendra = flavor(@mix, "Almendra").id
    assert_match "faltan 1", place.call({ "#{@x24.id}:#{almendra}x23" => 1 }).errors.join
    simple = catalog_product("Box de cookies", category: @mix.retail_category, active: true)
    RetailCatalog::PhotoUpload.add(product: simple, files: [image_upload("pixel.png")])
    assert_match "ya no permite elegir sabores", place.call({ "#{simple.variants.first.id}:#{almendra}x24" => 1 }).errors.join
    assert_match "no es válido", place.call({ "#{@x24.id}:1x2;" => 1 }).errors.join
    assert place.call({ "#{@x24.id}:#{almendra}x24" => 1, simple.variants.first.id.to_s => 2 }).ok?
  end

  test "stock online por variante: las cajas con distinta composición comparten el stock de su presentación" do
    @x24.update!(stock_mode: "limited", stock_input: "2")
    add_box(@x24, { "Almendra" => 24 })
    add_box(@x24, { "Maicena" => 24 })
    add_box(@x24, { "Cacao" => 24 })
    assert_match "quedan 2 unidades", flash[:alert]
    assert_equal 2, cart.values.sum

    checkout!
    assert_equal 0, @x24.reload.stock_quantity
  end

  test "vista previa (tienda cerrada, administrador): composición en el pedido de prueba y el mensaje" do
    RetailStoreSetting.current.update!(published: false)
    sign_in @admin
    add_box(@x24, { "Almendra" => 24 })
    assert_no_difference "RetailOrder.count" do
      checkout!
    end
    assert_select "#store-preview-items .store-composition li", text: /Almendra\s*× 24/
    assert_select "#store-preview-message", /- Almendra × 24/
  end

  test "la cookie del carrito nunca se pasa: con muchas cajas distintas de muchos sabores, avisa en vez de romperse" do
    big = RetailProduct.create!(name: "Mix grande", retail_category: @mix.retail_category, active: true, customizable_content: true,
      variants_attributes: [{ name: "Caja x 200", position: 1, price: "100.000", content_units: 200 }],
      flavors_attributes: (1..10).map { |i| { name: "Sabor #{i}", position: i } })
    RetailCatalog::PhotoUpload.add(product: big, files: [image_upload("pixel.png")])
    variant = big.reload.variants.first
    ids = big.ordered_flavors.map(&:id)
    # 30 composiciones distintas de 10 sabores (el peor caso realista: todas las cantidades de 2 cifras).
    messages = 30.times.map do |n|
      quantities = ids.to_h { |id| [id.to_s, "15"] }
      quantities[ids.first.to_s] = (10 + n).to_s
      quantities[ids.last.to_s] = (200 - 120 - (10 + n)).to_s
      post add_store_cart_path, params: { variant_id: variant.id, quantity: 99, flavors: quantities }
      flash[:alert]
    end
    assert_includes messages, Retail::StoreCart::FULL_MESSAGE
    assert cart.size >= 15, "entran al menos 15 cajas distintas de 10 sabores (entraron #{cart.size})"
    assert cart.size < 30

    get store_checkout_path # suma el token del checkout a la sesión
    assert_response :success
    set_cookie = Array(response.headers["Set-Cookie"]).join("\n").split("\n").find { |c| c.start_with?("#{Rails.application.config.session_options[:key]}=") }
    assert set_cookie, "la sesión se guardó"
    size = set_cookie.split(";").first.bytesize
    assert size < 4096, "la cookie de sesión mide #{size} bytes (límite: 4096)"
    puts "\n[medición] cajas de 10 sabores que entran: #{cart.size}; cookie con el checkout abierto: #{size} bytes" if ENV["MEDIR_CARRITO"]

    # Con un carrito común (cajas de 3 sabores) entran las 30 líneas.
    delete remove_item_store_cart_path, params: { line: cart.keys.first } while cart.any?
    30.times do |n|
      add_box(n.even? ? @x24 : @x12, n.even? ? { "Almendra" => 24 - (n / 2), "Maicena" => n / 2 } : { "Cacao" => 12 - (n / 2), "Almendra" => n / 2 })
    end
    puts "[medición] cajas de 2 sabores que entran: #{cart.size} (claves de ejemplo: #{cart.keys.first(2).inspect})" if ENV["MEDIR_CARRITO"]
    assert cart.size >= 25, "con cajas comunes entran al menos 25 líneas distintas (entraron #{cart.size})"
  end

  # Tope del carrito (decisión: se mantiene la cookie, ver docs/TIENDA_MINORISTA.md).
  def fill_cart_until_full
    big = RetailProduct.create!(name: "Mix grande", retail_category: @mix.retail_category, active: true, customizable_content: true,
      variants_attributes: [{ name: "Caja x 200", position: 1, price: "100.000", content_units: 200 }],
      flavors_attributes: (1..10).map { |i| { name: "Sabor #{i}", position: i } })
    RetailCatalog::PhotoUpload.add(product: big, files: [image_upload("pixel.png")])
    variant = big.reload.variants.first
    ids = big.ordered_flavors.map(&:id)
    add_box(@x24, { "Almendra" => 24 }) # una caja común que ya estaba en el carrito
    40.times do |n|
      quantities = ids.to_h { |id| [id.to_s, "15"] }
      quantities[ids.first.to_s] = (10 + n).to_s
      quantities[ids.last.to_s] = (200 - 120 - (10 + n)).to_s
      before = cart.dup
      post add_store_cart_path, params: { variant_id: variant.id, quantity: 1, flavors: quantities }
      return [big, variant, ids, before] if flash[:alert] == Retail::StoreCart::FULL_MESSAGE
    end
    flunk "el carrito nunca llegó al tope"
  end

  test "al llegar al tope: mensaje amigable, el carrito no cambia y el pedido se puede finalizar" do
    _, _, _, before = fill_cart_until_full
    assert_equal before, cart, "no se pierde ni cambia nada de lo que ya estaba"
    message = Retail::StoreCart::FULL_MESSAGE
    assert_no_match(/cookie|bytes|sesi[oó]n|KB/i, message)
    assert_match "Finalizá este pedido o escribinos por WhatsApp", message

    get store_cart_path
    assert_response :success
    assert_select ".store-line", before.size
    assert_select "a#store-go-checkout"

    lines = before.size
    assert_difference "RetailOrder.count", 1 do
      checkout!
    end
    order = RetailOrder.order(:id).last
    assert_equal lines, order.retail_order_items.count, "el pedido incluye todo lo que ya estaba en el carrito"
    assert_equal "Almendra × 24", order.retail_order_items.order(:position).first.composition_text
  end

  test "al llegar al tope, cambiar los sabores de una caja también está protegido: la caja queda como estaba" do
    big, _variant, _ids, before = fill_cart_until_full
    # Una composición más larga (más sabores, cantidades de dos cifras) que la caja común que estaba.
    common_key = before.keys.find { |key| Retail::BoxComposition.parse_key(key).first == @x24.id }
    # Una caja de 20 sabores: su clave es más larga que todo el espacio que queda en el carrito.
    huge = RetailProduct.create!(name: "Mix enorme", retail_category: @mix.retail_category, active: true, customizable_content: true,
      variants_attributes: [{ name: "Caja x 200", position: 1, price: "100.000", content_units: 200 }],
      flavors_attributes: (1..20).map { |i| { name: "Variedad #{i}", position: i } })
    RetailCatalog::PhotoUpload.add(product: huge, files: [image_upload("pixel.png")])
    huge.reload
    get store_cart_path # descarta el aviso anterior
    patch replace_item_store_cart_path, params: { line: common_key, variant_id: huge.variants.first.id, flavors: huge.ordered_flavors.to_h { |f| [f.id.to_s, "10"] } }
    assert_equal Retail::StoreCart::FULL_EDIT_MESSAGE, flash[:alert]
    assert_no_match(/cookie|bytes|KB/i, flash[:alert])
    assert_equal before, cart, "la caja editada y el resto del carrito quedan como estaban"

    # Una edición que no agranda el carrito sí se guarda.
    patch replace_item_store_cart_path, params: { line: common_key, variant_id: @x24.id, flavors: flavor_params(@mix, { "Maicena" => 24 }) }
    assert_equal "Actualizamos los sabores de la caja.", flash[:notice]
    assert_equal before.size, cart.size
    assert big.persisted?
  end
end
