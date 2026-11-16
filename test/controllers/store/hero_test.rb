require "test_helper"
require_relative "../../support/retail_helpers"
require_relative "../../support/retail_catalog_helpers"

# Portada configurable de la tienda (Tienda Minorista → Tienda online → Portada): título, subtítulo y
# foto de campaña. Sin foto, la portada usa la composición con fotos de productos.
class Store::HeroTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include RetailHelpers
  include RetailCatalogHelpers

  setup do
    Retail::StoreThrottle.reset!
    setup_retail
    RetailFulfillmentSetting.current
    @setting = RetailStoreSetting.current
    @setting.update!(published: true, published_at: Time.current)
    @tortas = catalog_category("Tortas", active: true)
    @torta = catalog_product("Torta de chocolate", category: @tortas, price: "20.000", active: true)
    RetailCatalog::PhotoUpload.add(product: @torta, files: [image_upload("pixel.png")])
  end

  test "sin configurar: textos por defecto, botón al catálogo y composición con fotos de productos" do
    get store_root_path
    assert_response :success
    assert_select "#store-hero-title", text: /Hecho a mano,\s*para compartir\./
    assert_select "#store-hero-title em", "para compartir."
    assert_select "#store-hero-text", RetailStoreSetting::DEFAULT_HERO_SUBTITLE
    assert_select "#store-hero-cta[href='#productos']", /Explorar productos/
    assert_select "#store-hero-custom", count: 0
    assert_select ".store-hero-main img[src*='/rails/active_storage/representations/proxy/']"
    assert_select ".store-card", count: 1 # la portada no agrega tarjetas al catálogo
  end

  test "admin: configura título en dos líneas, subtítulo y foto; la tienda los muestra" do
    sign_in @admin
    patch hero_admin_retail_catalog_store_settings_path, params: {
      hero_title: "  Navidad   en HANS \r\n tortas para regalar ", hero_subtitle: "Pedí antes del 20 de diciembre.",
      hero_image_alt: "Torta navideña", hero_image_position: "top", hero_image: image_upload("red.png")
    }
    assert_redirected_to admin_retail_catalog_store_settings_path(anchor: "store-hero")
    @setting.reload
    assert_equal "Navidad en HANS\ntortas para regalar", @setting.hero_title
    assert @setting.hero_image.attached?
    assert_equal "image/png", @setting.hero_image.content_type
    assert_equal @admin, @setting.updated_by

    get admin_retail_catalog_store_settings_path
    assert_select "#store-hero-current"

    get store_root_path
    assert_select "#store-hero-title", text: /Navidad en HANS\s*tortas para regalar/
    assert_select "#store-hero-title em", "tortas para regalar"
    assert_select "#store-hero-text", "Pedí antes del 20 de diciembre."
    assert_select "#store-hero-custom img[alt='Torta navideña'][src*='/rails/active_storage/representations/proxy/']"
    assert_select "#store-hero-custom img[style*='center top']"
    assert_select "#store-hero-cta", /Explorar productos/
    assert_select ".store-hero-side", count: 0 # sin la composición de productos
    assert_select ".store-card", count: 1
  end

  test "admin: reemplazar la foto cambia el archivo; quitarla vuelve a la composición de productos" do
    sign_in @admin
    patch hero_admin_retail_catalog_store_settings_path, params: { hero_image: image_upload("red.png") }
    first_blob = @setting.reload.hero_image.blob

    patch hero_admin_retail_catalog_store_settings_path, params: { hero_image: image_upload("pixel.jpg") }
    @setting.reload
    assert_not_equal first_blob.id, @setting.hero_image.blob.id
    assert_equal "image/jpeg", @setting.hero_image.content_type

    # Guardar solo textos no toca la foto.
    patch hero_admin_retail_catalog_store_settings_path, params: { hero_title: "Pascuas" }
    assert @setting.reload.hero_image.attached?
    assert_equal "Pascuas", @setting.hero_title

    delete hero_image_admin_retail_catalog_store_settings_path
    assert_redirected_to admin_retail_catalog_store_settings_path(anchor: "store-hero")
    assert_not @setting.reload.hero_image.attached?

    get store_root_path
    assert_select "#store-hero-custom", count: 0
    assert_select "#store-hero-title", "Pascuas"
    assert_select "#store-hero-title em", count: 0
  end

  test "admin: textos vacíos vuelven a los de por defecto" do
    @setting.update!(hero_title: "Día de la Madre", hero_subtitle: "Regalos dulces.")
    sign_in @admin
    patch hero_admin_retail_catalog_store_settings_path, params: { hero_title: " ", hero_subtitle: "" }
    @setting.reload
    assert_nil @setting.hero_title
    assert_nil @setting.hero_subtitle

    get store_root_path
    assert_select "#store-hero-title em", "para compartir."
  end

  test "admin: rechaza archivos que no son imágenes, demasiado grandes y textos largos, sin cambiar nada" do
    sign_in @admin
    patch hero_admin_retail_catalog_store_settings_path, params: { hero_title: "Nuevo", hero_image: image_upload("not_an_image.jpg") }
    assert_response :unprocessable_entity
    assert_select ".alert, #store-hero", /no es una imagen JPEG, PNG o WebP válida/
    assert_not @setting.reload.hero_image.attached?
    assert_nil @setting.hero_title

    patch hero_admin_retail_catalog_store_settings_path, params: { hero_image: image_upload("document.pdf") }
    assert_response :unprocessable_entity
    assert_not @setting.reload.hero_image.attached?

    big = Tempfile.new(["grande", ".png"])
    big.binmode
    big.write("\x89PNG\r\n\x1A\n".b + ("\0".b * (RetailCatalog::HeroImageUpload::MAX_BYTES + 1)))
    big.rewind
    patch hero_admin_retail_catalog_store_settings_path, params: { hero_image: Rack::Test::UploadedFile.new(big.path, "image/png") }
    assert_response :unprocessable_entity
    assert_not @setting.reload.hero_image.attached?

    patch hero_admin_retail_catalog_store_settings_path, params: { hero_title: "x" * (RetailStoreSetting::HERO_TITLE_MAX + 1), hero_image: image_upload("red.png") }
    assert_response :unprocessable_entity
    assert_nil @setting.reload.hero_title
    assert_not @setting.hero_image.attached?, "con un error en los textos no se sube la foto"

    patch hero_admin_retail_catalog_store_settings_path, params: { hero_image_position: "izquierda" }
    assert_equal "center", @setting.reload.hero_image_position
  ensure
    big&.close!
  end

  test "solo administradores configuran la portada" do
    customer_user = User.create!(email: "hero-cust-#{rand(1_000_000)}@example.com", password: "password123", role: "customer", customer: @customer)
    cook = User.create!(email: "hero-cook-#{rand(1_000_000)}@example.com", password: "password123", role: "production")
    [customer_user, cook].each do |user|
      sign_in user
      patch hero_admin_retail_catalog_store_settings_path, params: { hero_title: "Hackeado", hero_image: image_upload("red.png") }
      delete hero_image_admin_retail_catalog_store_settings_path
    end
    @setting.reload
    assert_nil @setting.hero_title
    assert_not @setting.hero_image.attached?

    sign_out cook
    patch hero_admin_retail_catalog_store_settings_path, params: { hero_title: "Sin sesión" }
    assert_nil @setting.reload.hero_title
  end
end
