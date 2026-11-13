require "test_helper"
require_relative "../../support/retail_helpers"
require_relative "../../support/retail_catalog_helpers"

# Variantes y stock online en las pantallas: tarjeta con el precio del tamaño más grande disponible,
# selector de tamaño en el detalle, carrito y pedido con la variante elegida, "Agotado", productos
# ocultos y el formulario del administrador (variantes, publicación y stock).
class Store::VariantsFlowTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include RetailHelpers
  include RetailCatalogHelpers

  MON = Time.zone.local(2026, 11, 9, 10)
  WED = Date.new(2026, 11, 11)

  setup do
    travel_to MON
    Retail::StoreThrottle.reset!
    setup_retail
    RetailFulfillmentSetting.current
    RetailStoreSetting.current.update!(published: true, published_at: Time.current)
    @tortas = catalog_category("Tortas #{rand(1_000_000)}", active: true)
    @nuez = published("Torta nuez", variants_attributes: [{ name: "18 cm", position: 1, price: "38.000" }, { name: "22 cm", position: 2, price: "46.000" }])
    @small, @large = @nuez.variants.to_a
    @box = published("Box Halloween", price: "18.000")
  end

  teardown { travel_back }

  def published(name, **attrs)
    product = catalog_product(name, category: @tortas, active: true, **attrs)
    RetailCatalog::PhotoUpload.add(product: product, files: [image_upload("pixel.png")])
    product.reload
  end

  def checkout!
    get store_checkout_path
    token = css_select("input[name=checkout_token]").first["value"]
    post store_checkout_path, params: { checkout_token: token, buyer_name: "María Pérez", buyer_phone: "223 5550000", buyer_email: "maria@example.com",
                                        delivery_kind: "pickup", pickup_date: WED.iso8601, planned_payment_method: "transfer", notes: "" }
  end

  test "catálogo: precio del tamaño más grande, tamaños disponibles y 'Elegir tamaño' en vez de agregar" do
    get store_root_path
    assert_response :success
    assert_select "#store_retail_product_#{@nuez.id} .store-card-price", "$46.000"
    assert_select "#store_retail_product_#{@nuez.id} .store-card-sizes", "18 cm · 22 cm"
    assert_select "#store_retail_product_#{@nuez.id} a", text: "Elegir tamaño"
    assert_select "#store_retail_product_#{@box.id} input[name=variant_id][value='#{@box.variants.first.id}']"

    @large.update!(active: false)
    get store_root_path
    assert_select "#store_retail_product_#{@nuez.id} .store-card-price", "$38.000"
  end

  test "catálogo con varias tortas: el orden de tamaños y el precio no dependen de cómo se cargan" do
    oreo = published("Oreo capas", variants_attributes: [{ name: "10 cm", position: 1, price: "10.000" }, { name: "18 cm", position: 2, price: "47.000" }, { name: "22 cm", position: 3, price: "54.000" }])
    # Ids de variantes a propósito fuera de orden respecto del tamaño.
    oreo.variants.find_by!(name: "18 cm").tap { |v| v.update!(position: 3) }
    oreo.variants.find_by!(name: "22 cm").tap { |v| v.update!(position: 2) }
    oreo.variants.find_by!(name: "18 cm").update!(position: 2)
    oreo.variants.find_by!(name: "22 cm").update!(position: 3)
    get store_root_path
    assert_select "#store_retail_product_#{oreo.id} .store-card-sizes", "10 cm · 18 cm · 22 cm"
    assert_select "#store_retail_product_#{oreo.id} .store-card-price", "$54.000"
    loaded = RetailProduct.for_store.includes(:variants).ordered.find { |p| p.id == oreo.id }
    assert_equal ["10 cm", "18 cm", "22 cm"], loaded.variants.map(&:name)
  end

  test "detalle: elige el tamaño con su precio; arranca en el más grande disponible" do
    get store_product_path(id: @nuez.id)
    assert_response :success
    assert_select "#store-product-price", "$46.000"
    assert_select "#store-variants input[name=variant_id]", 2
    assert_select "#variant-#{@large.id}[checked]"
    assert_select "#variant-#{@small.id}[data-price='$38.000']"

    @large.update!(stock_quantity: 0)
    get store_product_path(id: @nuez.id)
    assert_select "#store-product-price", "$38.000"
    assert_select "#variant-#{@small.id}[checked]"
    assert_select "#variant-#{@large.id}[disabled]"
  end

  test "detalle: la descripción propia de cada variante se muestra con su variante" do
    @small.update!(description: "Mínimo 4 por variedad.")
    @large.update!(description: "Mínimo 5 variedades.")
    get store_product_path(id: @nuez.id)
    assert_select "#variant-description-#{@large.id}:not([hidden])", /Mínimo 5 variedades/
    assert_select "#variant-description-#{@small.id}[hidden]", /Mínimo 4 por variedad/
  end

  test "carrito y pedido con la variante elegida y su precio del servidor" do
    post add_store_cart_path, params: { variant_id: @small.id, quantity: 2, price: "1" }
    post add_store_cart_path, params: { product_id: @nuez.id, quantity: 1 }
    assert_equal "Elegí el tamaño de “Torta nuez”.", flash[:alert]

    get store_cart_path
    assert_select "#cart_retail_product_variant_#{@small.id} .store-line-variant", "18 cm"
    assert_select "#store-cart-subtotal", "$76.000"

    checkout!
    order = RetailOrder.order(:id).last
    assert order.source_store?
    item = order.retail_order_items.first
    assert_equal ["Torta nuez · 18 cm", 3_800_000, @small.id], [item.display_name, item.unit_price_cents, item.retail_product_variant_id]
    get store_order_path(order.public_token)
    assert_match "Torta nuez · 18 cm", response.body
  end

  test "agotado: se muestra y no se puede comprar; oculto: no aparece ni por enlace directo" do
    @box.variants.first.update!(stock_quantity: 0)
    get store_root_path
    assert_select "#store_retail_product_#{@box.id} .store-badge-soldout", "Agotado"
    get store_product_path(id: @box.id)
    assert_select "#store-sold-out"
    assert_select "#store-add-form", 0
    post add_store_cart_path, params: { variant_id: @box.variants.first.id, quantity: 1 }, headers: { "HTTP_REFERER" => store_root_url }
    assert_equal "Ese producto no está disponible.", flash[:alert]

    @nuez.update!(active: false)
    get store_product_path(id: @nuez.id)
    assert_response :not_found
    post add_store_cart_path, params: { variant_id: @large.id, quantity: 1 }, headers: { "HTTP_REFERER" => store_root_url }
    assert_equal "Ese producto no está disponible.", flash[:alert]
  end

  test "stock limitado en la pantalla: el carrito no deja pasar del disponible" do
    @box.variants.first.update!(stock_quantity: 2)
    post add_store_cart_path, params: { variant_id: @box.variants.first.id, quantity: 5 }
    follow_redirect!
    assert_match "quedan 2 unidades", response.body
    assert_equal 2, Retail::StoreCart.new(session).contents[@box.variants.first.id.to_s]
  end

  # --- Administrador ---------------------------------------------------------------------------------

  test "admin: crear una torta con dos tamaños, stock limitado en uno y publicada por defecto" do
    sign_in @admin
    get new_admin_retail_catalog_product_path
    assert_select "#retail_product_active[checked]", 1, "los productos nuevos nacen publicados"

    post admin_retail_catalog_products_path, params: { retail_product: {
      name: "Torta oreo", retail_category_id: @tortas.id, active: "1", description: "Galletitas, dulce de leche y crema.",
      variants_attributes: {
        "0" => { name: "18 cm", price: "42.000", position: "1", active: "1", stock_mode: "unlimited", stock_input: "" },
        "1" => { name: "22 cm", price: "50.000", position: "2", active: "1", stock_mode: "limited", stock_input: "20" }
      }
    } }
    product = RetailProduct.find_by!(name: "Torta oreo")
    assert_redirected_to admin_retail_catalog_product_path(product)
    assert product.active?
    assert_equal [["18 cm", 4_200_000, nil], ["22 cm", 5_000_000, 20]], product.variants.map { |v| [v.name, v.price_cents, v.stock_quantity] }
    assert_equal 5_000_000, product.price_cents

    get admin_retail_catalog_product_path(product)
    assert_select "#retail-product-variants tbody tr", 2
    assert_match "Sin límite", response.body

    post admin_retail_catalog_products_path, params: { retail_product: {
      name: "Mal", retail_category_id: @tortas.id, variants_attributes: { "0" => { name: "", price: "1", position: "1" }, "1" => { name: "", price: "2", position: "2" } }
    } }
    assert_response :unprocessable_entity
    assert_match "cada una necesita un nombre", response.body

    post admin_retail_catalog_products_path, params: { retail_product: {
      name: "Negativo", retail_category_id: @tortas.id, variants_attributes: { "0" => { price: "1", stock_mode: "limited", stock_input: "-3" } }
    } }
    assert_response :unprocessable_entity
  end

  test "admin: ocultar desde el formulario y no pisar el stock si cambió mientras se editaba" do
    sign_in @admin
    variant = @box.variants.first
    variant.update!(stock_quantity: 10)
    get edit_admin_retail_catalog_product_path(@box)
    assert_response :success
    seen = css_select("input[name='retail_product[variants_attributes][0][stock_quantity_seen]']").first["value"]
    assert_equal "10", seen

    variant.update!(stock_quantity: 7) # entró un pedido mientras tanto
    patch admin_retail_catalog_product_path(@box), params: { retail_product: { active: "0", variants_attributes: { "0" => { id: variant.id, stock_mode: "limited", stock_input: "15", stock_quantity_seen: seen } } } }
    assert_response :unprocessable_entity
    assert_match "cambió mientras editabas", response.body
    assert_equal 7, variant.reload.stock_quantity
    assert @box.reload.active?

    patch admin_retail_catalog_product_path(@box), params: { retail_product: { active: "0", variants_attributes: { "0" => { id: variant.id, stock_mode: "unlimited", stock_input: "", stock_quantity_seen: "7" } } } }
    assert_redirected_to admin_retail_catalog_product_path(@box)
    assert_not @box.reload.active?
    assert_nil variant.reload.stock_quantity
  end
end
