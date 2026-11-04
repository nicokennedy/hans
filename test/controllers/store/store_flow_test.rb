require "test_helper"
require_relative "../../support/retail_helpers"
require_relative "../../support/retail_catalog_helpers"

# Etapa 4: la tienda pública de punta a punta (catálogo, carrito, checkout, pedido recibido), la
# publicación (cerrada / vista previa / publicada), la seguridad y la llegada al panel interno.
class Store::StoreFlowTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include RetailHelpers
  include RetailCatalogHelpers

  MON = Time.zone.local(2026, 11, 9, 10) # lunes 10:00 en Argentina
  WED = Date.new(2026, 11, 11)

  setup do
    travel_to MON
    Retail::StoreThrottle.reset!
    setup_retail
    RetailFulfillmentSetting.current
    @setting = RetailStoreSetting.current
    @zone2 = RetailDeliveryZone.find_by!(name: "Zona 2")
    @tortas = catalog_category("Tortas", active: true, position: 2)
    @cookies_cat = catalog_category("Cookies", active: true, position: 1)
    @torta = published("Torta de chocolate", "20.000", @tortas, description: "Bizcochuelo de chocolate.")
    @cookies = published("Cookies", "4.000", @cookies_cat)
    @hidden = catalog_product("Producto inactivo", category: @tortas, price: "1.000", active: false)
    n = rand(1_000_000)
    @customer_user = User.create!(email: "store-cust-#{n}@example.com", password: "password123", role: "customer", customer: @customer)
  end

  teardown do
    travel_back
  end

  def published(name, price, category, **attrs)
    product = catalog_product(name, category: category, price: price, active: true, **attrs)
    RetailCatalog::PhotoUpload.add(product: product, files: [image_upload("pixel.png")])
    product
  end

  def open_store!
    @setting.update!(published: true, published_at: Time.current)
  end

  def checkout_token
    get store_checkout_path
    assert_response :success
    css_select("input[name=checkout_token]").first["value"]
  end

  def checkout_params(overrides = {})
    { checkout_token: @token, buyer_name: "María Pérez", buyer_phone: "223 5550000", buyer_email: "maria@example.com",
      delivery_kind: "pickup", pickup_date: WED.iso8601, planned_payment_method: "transfer", notes: "Texto: Feliz cumple" }.merge(overrides)
  end

  def fill_cart
    post add_store_cart_path, params: { product_id: @torta.id, quantity: 1 }
    post add_store_cart_path, params: { product_id: @cookies.id, quantity: 2 }
  end

  # --- Publicación ---

  test "cerrada: el público ve Próximamente en todas las páginas y no puede usar carrito ni checkout" do
    get store_root_path
    assert_select "#store-closed"
    assert_select "#store-closed h1", "Próximamente"
    assert_select "a[href=?]", "https://wa.me/5492235275412"
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
    assert_select "#store-torta", count: 0

    get store_product_path(id: @torta.id)
    assert_select "#store-closed"
    post add_store_cart_path, params: { product_id: @torta.id, quantity: 1 }
    assert_select "#store-closed"
    assert_no_difference "RetailOrder.count" do
      post store_checkout_path, params: { checkout_token: "x" * 32, buyer_name: "Bot" }
    end
    assert_select "#store-closed"

    sign_in @customer_user # un cliente mayorista tampoco la ve
    get store_root_path
    assert_select "#store-closed"
  end

  test "cerrada: un administrador la recorre en vista previa y el checkout no registra pedidos" do
    sign_in @admin
    get store_root_path
    assert_response :success
    assert_select "#store-preview-bar"
    fill_cart
    @token = checkout_token
    assert_select "#store-checkout-form[data-turbo=false]" # la vista previa responde con una página, no con un redirect

    sequence = -> { RetailOrder.connection.select_value("SELECT last_value FROM retail_orders_id_seq") }
    before_sequence = sequence.call
    assert_no_difference ["RetailOrder.count", "RetailOrderItem.count", "RetailOrderStatusChange.count", "StockMovement.count"] do
      post store_checkout_path, params: checkout_params(delivery_kind: "delivery", delivery_date: WED.iso8601, delivery_zone_id: @zone2.id, address: "Alem 123")
    end
    assert_equal before_sequence, sequence.call, "la vista previa no consume números de pedido"
    assert_response :success
    assert_select "#store-preview", text: /no se registró ningún pedido/
    assert_select "#store-preview-total", "$34.000"
    assert_select "#store-preview-message", text: /\[VISTA PREVIA DE PRUEBA/
    assert_select "#store-preview-message", text: /Zona: Zona 2/
    assert_select "#store-preview-message", text: /pedido \(número de prueba\)/
    assert_select "#store-preview-items li", 2

    post store_checkout_path, params: checkout_params(pickup_date: "2026-11-15")
    assert_response :unprocessable_entity
    assert_select "#store-checkout-errors li", /domingos/
    assert_equal 3, Retail::StoreCart.new(session).count, "el carrito queda para seguir probando"
  end

  test "publicada: se ve sin iniciar sesión" do
    open_store!
    get store_root_path
    assert_response :success
    assert_nil response.headers["X-Robots-Tag"]
    assert_select "#store-preview-bar", count: 0
  end

  # --- Catálogo ---

  test "catálogo: solo productos publicados, por categoría en el orden configurado, con precio minorista" do
    open_store!
    hidden_category = catalog_category("Oculta", active: false)
    published("En categoría oculta", "1.000", hidden_category)
    catalog_product("Sin foto", category: @tortas, price: "1.000", active: true)

    get store_root_path
    assert_response :success
    assert_equal ["Cookies", "Tortas"], css_select(".store-section-title").map(&:text)
    assert_select "#store_retail_product_#{@torta.id} .store-card-name", "Torta de chocolate"
    assert_select "#store_retail_product_#{@torta.id} .store-card-price", "$20.000"
    assert_select "#store_retail_product_#{@torta.id} img[src*='/rails/active_storage/representations/proxy/']"
    assert_select ".store-card", count: 2
    assert_no_match "Producto inactivo", response.body
    assert_no_match "En categoría oculta", response.body
    assert_no_match "Sin foto", response.body
    assert_no_match "Oculta", response.body
  end

  test "detalle: nombre, fotos, descripción, precio, categoría y cantidad; lo no publicado da 404" do
    open_store!
    RetailCatalog::PhotoUpload.add(product: @torta, files: [image_upload("red.png")])
    get store_product_path(id: "#{@torta.id}-torta-de-chocolate")
    assert_response :success
    assert_select "h1.store-product-name", "Torta de chocolate"
    assert_select "#store-product-price", "$20.000"
    assert_select ".store-product-description", /Bizcochuelo de chocolate/
    assert_select ".store-eyebrow", "Tortas"
    assert_select ".store-gallery-thumb", 2
    assert_select ".store-gallery-main img[src*='/rails/active_storage/representations/proxy/']"
    assert_select "#store-add-form input[name=quantity][max='99']"

    get store_product_path(id: @hidden.id)
    assert_response :not_found
  end

  # --- Carrito ---

  test "carrito: agregar, cambiar cantidad, quitar, subtotales y persistencia entre páginas" do
    open_store!
    fill_cart
    assert_redirected_to store_cart_path
    get store_root_path
    assert_select "#store-cart-link .store-cart-count", "3"

    get store_cart_path
    assert_select ".store-line", 2
    assert_select "#cart_retail_product_#{@cookies.id} .store-line-total", "$8.000"
    assert_select "#store-cart-subtotal", "$28.000"

    patch update_item_store_cart_path, params: { product_id: @cookies.id, quantity: 5 }
    get store_cart_path
    assert_select "#store-cart-subtotal", "$40.000"

    patch update_item_store_cart_path, params: { product_id: @cookies.id, quantity: 0 }
    follow_redirect!
    assert_select ".store-flash-error", /cantidad de 1 a 99/

    delete remove_item_store_cart_path, params: { product_id: @cookies.id }
    get store_cart_path
    assert_select ".store-line", 1
    assert_select "#store-cart-subtotal", "$20.000"
  end

  test "carrito: no acepta productos no publicados ni precios del navegador" do
    open_store!
    post add_store_cart_path, params: { product_id: @hidden.id, quantity: 1 }, headers: { "HTTP_REFERER" => store_root_url }
    assert_redirected_to store_root_url
    assert_equal "Ese producto no está disponible.", flash[:alert]

    post add_store_cart_path, params: { product_id: @torta.id, quantity: 1, price: "1", unit_price_cents: 1 }
    get store_cart_path
    assert_select "#store-cart-subtotal", "$20.000"
  end

  # --- Checkout ---

  test "checkout: muestra modalidades, solo fechas válidas, zonas con cobertura y precio, y formas de pago" do
    open_store!
    RetailServiceClosure.create!(date: WED + 1, service: "pickup", reason: "Inventario")
    fill_cart
    get store_checkout_path
    assert_response :success

    pickup_dates = css_select("#pickup_date option").map { |o| o["value"] }.reject(&:blank?)
    delivery_dates = css_select("#delivery_date option").map { |o| o["value"] }.reject(&:blank?)
    assert_equal "2026-11-11", pickup_dates.first, "lunes → primera fecha el miércoles"
    assert_not_includes pickup_dates, "2026-11-12", "fecha sin retiro"
    assert_includes delivery_dates, "2026-11-12"
    assert pickup_dates.none? { |d| Date.iso8601(d).sunday? }
    assert delivery_dates.none? { |d| Date.iso8601(d).sunday? }
    assert_select "#pickup_date option[value='2026-11-11']", "Miércoles 11/11 · 14:00 a 17:00 hs"
    assert_select "#delivery_date option[value='2026-11-14']", "Sábado 14/11 · 8:30 a 13:00 hs"
    assert_select ".store-option", text: /Retiro por zona Plaza del Agua\s*Gratis/
    assert_select ".store-option-text", text: "Lunes a viernes: 14:00 a 17:00 hs · sábado: 11:00 a 13:00 hs"
    assert_select ".store-zone", 3
    assert_select ".store-zone", text: /Zona 2\s*\$6\.000\s*Centro, zona Facultad/
    assert_select "input[name=planned_payment_method]", 2
    assert_select ".store-option", text: "Transferencia bancaria"
    assert_select ".store-option", text: "Efectivo"
    assert_select "textarea[name=notes][placeholder=?]", "Texto para la torta, observaciones, alergias, etc."
    assert_select "#store-submit", text: /Enviar pedido por WhatsApp/
    assert_select "#store-pickup-details", /por WhatsApp/
    assert_no_match(/Retiro en (el local|sucursal)/i, response.body)
  end

  test "checkout completo: crea el pedido pendiente, vacía el carrito y muestra el pedido recibido con WhatsApp" do
    open_store!
    fill_cart
    @token = checkout_token
    assert_select "#store-checkout-form[data-turbo=true]"

    assert_difference "RetailOrder.count", 1 do
      post store_checkout_path, params: checkout_params(delivery_kind: "delivery", delivery_date: WED.iso8601,
        delivery_zone_id: @zone2.id, address: "Alem 123", planned_payment_method: "cash_on_delivery")
    end
    order = RetailOrder.order(:id).last
    assert_redirected_to store_order_path(order.public_token)
    assert order.source_store?
    assert order.confirmation_awaiting?
    assert_equal 3_400_000, order.total_cents
    assert_equal 600_000, order.shipping_cents
    assert_equal "Zona 2", order.delivery_zone_name
    assert_equal "cash_on_delivery", order.planned_payment_method
    assert_equal "maria@example.com", order.buyer_email
    assert_equal "Texto: Feliz cumple", order.notes
    assert Retail::StoreCart.new(session).empty?

    follow_redirect!
    assert_response :success
    assert_select "#store-order-number", order.number
    assert_select "#store-order-total", "$34.000"
    assert_select "#store-order[data-store-whatsapp-auto-value=true]"
    link = css_select("#store-whatsapp-button").first["href"]
    assert link.start_with?("https://wa.me/5492235275412?text=")
    text = URI.decode_www_form_component(link.split("?text=").last)
    assert_includes text, "Quiero confirmar mi pedido ##{order.number}."
    assert_includes text, "Total: $34.000"
    assert_includes text, "Forma de pago: Efectivo"
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
    assert_no_match(/enviado|recibido por HANS|leído/i, css_select("#store-order .store-received").text.gsub("Recibimos tu pedido", ""))

    # Recargar o volver desde WhatsApp: el mismo pedido, sin abrir WhatsApp solo otra vez.
    get store_order_path(order.public_token)
    assert_select "#store-order[data-store-whatsapp-auto-value=false]"
  end

  test "retiro gratis con transferencia: sin zona ni dirección; datos bancarios solo si están cargados" do
    open_store!
    fill_cart
    @token = checkout_token
    post store_checkout_path, params: checkout_params(delivery_zone_id: @zone2.id, address: "no va")
    order = RetailOrder.order(:id).last
    assert_equal 0, order.shipping_cents
    assert_nil order.delivery_zone
    assert_nil order.address
    follow_redirect!
    assert_select "#store-order-shipping", "Gratis"
    assert_select "#store-transfer-details", /Te pasamos los datos para transferir por WhatsApp/

    @setting.update!(bank_transfer_details: "Alias: HANS.PASTELERIA")
    get store_order_path(order.public_token)
    assert_select "#store-transfer-details", /Alias: HANS.PASTELERIA/
  end

  test "errores claros sin crear nada: fecha inválida, domingo, zona inexistente y datos faltantes" do
    open_store!
    fill_cart
    @token = checkout_token
    assert_no_difference "RetailOrder.count" do
      post store_checkout_path, params: checkout_params(pickup_date: "2026-11-10")
      assert_response :unprocessable_entity
      assert_select "#store-checkout-errors li", /anticipación/

      post store_checkout_path, params: checkout_params(pickup_date: "2026-11-15")
      assert_select "#store-checkout-errors li", /domingos/

      post store_checkout_path, params: checkout_params(delivery_kind: "delivery", delivery_date: WED.iso8601, delivery_zone_id: "999999", address: "Alem 1")
      assert_select "#store-checkout-errors li", /zona de envío elegida no está disponible/

      post store_checkout_path, params: checkout_params(buyer_email: "", buyer_phone: "", pickup_date: "")
      assert_select "#store-checkout-errors li", /email/
      assert_select "#store-checkout-errors li", /celular/
      assert_select "#store-checkout-errors li", /fecha/
      assert_select "input[name=buyer_name][value='María Pérez']" # conserva lo que el cliente ya escribió
    end
  end

  test "manipular precios, envío o totales desde el navegador no cambia nada" do
    open_store!
    fill_cart
    @token = checkout_token
    post store_checkout_path, params: checkout_params(delivery_kind: "delivery", delivery_date: WED.iso8601, delivery_zone_id: @zone2.id,
      address: "Alem 123", shipping: "0", shipping_cents: 0, total_cents: 1, subtotal_cents: 1, price: 1,
      items: [{ product_id: @torta.id, unit_price: "1", quantity: 1 }], delivery_zone_name: "Gratis")
    order = RetailOrder.order(:id).last
    assert_equal 2_800_000, order.subtotal_cents
    assert_equal 600_000, order.shipping_cents
    assert_equal 3_400_000, order.total_cents
    assert_equal "Zona 2", order.delivery_zone_name
    assert_equal 2, order.retail_order_items.count
  end

  test "sin duplicados: doble envío, recarga del POST y volver atrás dan el mismo pedido" do
    open_store!
    fill_cart
    @token = checkout_token
    params = checkout_params

    assert_difference "RetailOrder.count", 1 do
      post store_checkout_path, params: params
      first = response.location
      post store_checkout_path, params: params # doble toque / recarga del formulario ya enviado
      assert_equal first, response.location
      get store_checkout_path # volver atrás: el carrito ya está vacío
      assert_redirected_to store_cart_path
      post store_checkout_path, params: params
      assert_equal first, response.location
    end
  end

  test "dos envíos simultáneos con el mismo token crean un solo pedido" do
    open_store!
    fill_cart
    @token = checkout_token
    cart = Retail::StoreCart.new(session).contents
    attrs = checkout_params.except(:checkout_token, :pickup_date).merge(delivery_date: WED.iso8601)
    first = Retail::PlaceStoreOrder.call(attributes: attrs, cart: cart, request_token: "store-#{@token}")
    second = Retail::PlaceStoreOrder.call(attributes: attrs, cart: cart, request_token: "store-#{@token}")
    assert_equal first.record, second.record
    assert second.duplicate?
  end

  test "un token ajeno o vencido no crea pedido ni muestra pedidos de otros" do
    open_store!
    fill_cart
    @token = checkout_token
    post store_checkout_path, params: checkout_params
    other_order = RetailOrder.order(:id).last

    # Otra sesión que reenvía el token de esa compra: no ve ese pedido.
    reset!
    fill_cart
    checkout_token
    assert_no_difference "RetailOrder.count" do
      post store_checkout_path, params: checkout_params(checkout_token: @token)
    end
    assert_response :unprocessable_entity
    assert_select "#store-checkout-errors", /se venció/
    assert_no_match other_order.public_token, response.body
  end

  test "campo trampa (honeypot): no crea el pedido" do
    open_store!
    fill_cart
    @token = checkout_token
    assert_no_difference "RetailOrder.count" do
      post store_checkout_path, params: checkout_params(website: "http://spam.example")
    end
    assert_redirected_to store_cart_path
  end

  test "límite de pedidos por IP" do
    open_store!
    6.times do |i|
      fill_cart
      @token = checkout_token
      post store_checkout_path, params: checkout_params(buyer_name: "Cliente #{i}")
    end
    assert_response :too_many_requests
    assert_equal 5, RetailOrder.source_store.count
  end

  test "protección CSRF: un POST sin token de autenticidad se rechaza" do
    open_store!
    ActionController::Base.allow_forgery_protection = true
    begin
      assert_no_difference "RetailOrder.count" do
        post add_store_cart_path, params: { product_id: @torta.id, quantity: 1 }
        assert_response :unprocessable_entity
      end
    ensure
      ActionController::Base.allow_forgery_protection = false
    end
  rescue ActionController::InvalidAuthenticityToken
    pass
  end

  # --- Pedido recibido ---

  test "pedido recibido: solo con el token; nunca por id; vence 30 días después de la entrega" do
    open_store!
    fill_cart
    @token = checkout_token
    post store_checkout_path, params: checkout_params
    order = RetailOrder.order(:id).last
    assert_equal 32, order.public_token.length

    get "/tienda/pedido/#{order.id}"
    assert_response :not_found
    get store_order_path("A" * 32)
    assert_response :not_found
    assert_no_match "María Pérez", response.body

    manual = create_retail
    get store_order_path(manual.public_token)
    assert_response :not_found, "los pedidos manuales no tienen página pública"

    travel_to WED + 31
    get store_order_path(order.public_token)
    assert_response :not_found
  end

  test "pedido recibido sigue visible aunque la tienda se cierre después" do
    open_store!
    fill_cart
    @token = checkout_token
    post store_checkout_path, params: checkout_params
    order = RetailOrder.order(:id).last
    @setting.update!(published: false)
    get store_order_path(order.public_token)
    assert_response :success
    assert_select "#store-order-number", order.number
  end

  # --- Panel interno ---

  test "el pedido llega a Pedidos Minoristas como pendiente y se confirma con el flujo existente" do
    open_store!
    fill_cart
    @token = checkout_token
    post store_checkout_path, params: checkout_params(delivery_kind: "delivery", delivery_date: WED.iso8601, delivery_zone_id: @zone2.id, address: "Alem 123")
    order = RetailOrder.order(:id).last

    sign_in @admin
    get admin_retail_orders_path
    assert_response :success
    assert_match order.number, response.body

    get admin_retail_order_path(order)
    assert_response :success
    assert_select "#retail-order-email", "maria@example.com"
    assert_select "#retail-order-zone", "Zona 2"
    assert_select "#retail-order-window", "8:30 a 13:00 hs"
    assert_select "#retail-order-payment-method", "Transferencia bancaria"
    assert_select "#retail-confirmation-status", /Pendiente de confirmación/
    assert_select "#retail-items", /Torta de chocolate/

    post confirm_admin_retail_order_path(order)
    assert order.reload.confirmation_confirmed?
    assert order.payment_pending?, "confirmar no registra pagos"
    get store_order_path(order.public_token)
    assert_select "#store-order-confirmed"
  end

  # --- Administración de la tienda ---

  test "Tienda online: solo admin; publicar exige confirmación; guarda WhatsApp y datos bancarios" do
    sign_in @customer_user
    get admin_retail_catalog_store_settings_path
    assert_response :redirect
    patch publish_admin_retail_catalog_store_settings_path, params: { confirm: "1" }
    assert_not @setting.reload.published?

    cook = User.create!(email: "store-cook-#{rand(1_000_000)}@example.com", password: "password123", role: "production")
    sign_in cook
    patch publish_admin_retail_catalog_store_settings_path, params: { confirm: "1" }
    assert_not @setting.reload.published?

    sign_in @admin
    get admin_retail_catalog_store_settings_path
    assert_response :success
    assert_select "#store-status", "Cerrada al público"
    assert_select "#store-readiness", /2<\/strong> productos visibles|2 productos visibles/

    patch publish_admin_retail_catalog_store_settings_path
    assert_not @setting.reload.published?, "sin la casilla no se publica"

    patch publish_admin_retail_catalog_store_settings_path, params: { confirm: "1" }
    assert @setting.reload.published?
    assert_equal @admin, @setting.updated_by

    patch admin_retail_catalog_store_settings_path, params: { whatsapp_number: "+54 9 223 527-5412", bank_transfer_details: "Alias: HANS" }
    assert_equal "5492235275412", @setting.reload.whatsapp_number
    assert_equal "Alias: HANS", @setting.bank_transfer_details
    patch admin_retail_catalog_store_settings_path, params: { whatsapp_number: "123" }
    assert_response :unprocessable_entity
    assert_equal "5492235275412", @setting.reload.whatsapp_number

    patch unpublish_admin_retail_catalog_store_settings_path
    assert_not @setting.reload.published?
  end

  test "la tienda no expone el panel ni el portal mayorista: sin sesión siguen pidiendo login" do
    open_store!
    get store_root_path
    assert_no_match(/admin|R2_|cloudflarestorage|heroku/i, response.body.gsub(%r{/rails/active_storage/[^"]+}, ""))
    get admin_retail_orders_path
    assert_redirected_to new_user_session_path
    get dashboard_path
    assert_redirected_to new_user_session_path
  end

  test "sin regresiones mayoristas: el portal y el carrito mayorista siguen funcionando" do
    open_store!
    sign_in @customer_user
    get dashboard_path
    assert_response :success
    get cart_path
    assert_response :success
    fill_cart # el carrito de la tienda es otro: no toca session[:cart]
    assert session[:cart].blank?
  end
end
