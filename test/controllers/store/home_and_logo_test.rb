require "test_helper"
require "zlib"
require_relative "../../support/retail_helpers"
require_relative "../../support/retail_catalog_helpers"

# Rediseño 2026, Etapa 1: la tienda ya no muestra la portada (hero); la primera sección debajo del
# encabezado es «Nuestras especialidades», después la información comercial, la navegación por
# categorías y el catálogo. El encabezado muestra el logo cargado en Tienda Minorista → Tienda online
# (o el texto "HANS Pastelería" si no hay logo). Los datos de la portada se conservan.
class Store::HomeAndLogoTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include RetailHelpers
  include RetailCatalogHelpers

  setup do
    # PNG transparente generado al ejecutar los tests, sin distribuir imágenes de prueba.
    @transparent_logo = Tempfile.new(["logo", ".png"])
    @transparent_logo.binmode
    chunk = ->(type, data) { [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N") }
    @transparent_logo.write("\x89PNG\r\n\x1a\n".b +
      chunk.call("IHDR", [200, 80, 8, 6, 0, 0, 0].pack("NNC5")) +
      chunk.call("IDAT", Zlib.deflate(("\0".b * 801) * 80)) +
      chunk.call("IEND", "".b))
    @transparent_logo.flush
    Retail::StoreThrottle.reset!
    setup_retail
    RetailFulfillmentSetting.current
    @setting = RetailStoreSetting.current
    @setting.update!(published: true, published_at: Time.current)
    @tortas = catalog_category("Tortas", active: true)
    @torta = catalog_product("Torta de chocolate", category: @tortas, price: "20.000", active: true, featured: true)
    RetailCatalog::PhotoUpload.add(product: @torta, files: [image_upload("pixel.png")])
  end

  teardown do
    @transparent_logo&.close!
  end

  # --- Página principal ---

  test "sin portada: especialidades, información comercial, categorías y catálogo, en ese orden" do
    get store_root_path
    assert_response :success
    assert_select "#store-hero, .store-hero, #store-hero-title, #store-hero-cta", count: 0

    body = response.body
    markers = ['<header class="store-header"', 'id="categorias-title"', 'id="como-comprar"', 'class="store-chips"', 'id="destacados"', %(id="categoria-#{@tortas.id}")]
    order = markers.map { |marker| body.index(marker) }
    assert order.all?, "faltan secciones: #{order.inspect}"
    assert_equal order.sort, order, "las secciones no están en el orden pedido"

    assert_select "#categorias-title", /Nuestras\s*especialidades/
    assert_select ".store-category-tile", 1
    assert_select "#como-comprar .store-perks-list li", 4
    assert_select "#como-comprar", /Retiro por zona Plaza del Agua/
    assert_select "#como-comprar", /Sin costo/
    assert_select "#como-comprar", /Envío a domicilio/
    assert_select "#como-comprar", /Costo según la zona/
    assert_select "#como-comprar", /Pedí con 2 días de anticipación/
    assert_select "#como-comprar", /Confirmación por WhatsApp/
    assert_select "#como-comprar", /Te respondemos personalmente/
    assert_select ".store-card", 2 # destacados + su categoría, igual que antes
    assert_select ".store-header-link[href$='#como-comprar']", "Cómo comprar"
  end

  test "los datos de la portada se conservan pero no se muestran" do
    @setting.update!(hero_title: "Navidad en HANS", hero_subtitle: "Pedí antes del 20.")
    RetailCatalog::HeroImageUpload.attach(setting: @setting, file: image_upload("red.png"))
    @setting.save!

    get store_root_path
    assert_response :success
    assert_no_match "Navidad en HANS", response.body
    assert_no_match "Pedí antes del 20.", response.body
    assert_select "#store-hero-custom", count: 0

    @setting.reload
    assert_equal "Navidad en HANS", @setting.hero_title
    assert @setting.hero_image.attached?, "la foto de portada no se borra"

    sign_in @admin
    get admin_retail_catalog_store_settings_path
    assert_response :success
    assert_select "#store-hero, #store-hero-form", count: 0
    assert_select "#store-logo-form"
  end

  test "catálogo vacío: aviso y la información comercial igual se muestra" do
    @torta.update!(active: false)
    get store_root_path
    assert_select "#store-empty-catalog"
    assert_select "#como-comprar.store-perks-standalone"
    assert_select "#categorias-title", count: 0
  end

  # --- Logo ---

  test "sin logo: el encabezado conserva el texto HANS Pastelería" do
    get store_root_path
    assert_select "#store-brand .store-brand-name", "HANS"
    assert_select "#store-brand .store-brand-sub", "Pastelería"
    assert_select "#store-brand-logo", count: 0
    # Pie: sin logo, el texto HANS; la frase nueva.
    assert_select ".store-footer #store-footer-brand", "HANS"
    assert_select ".store-footer #store-footer-logo", count: 0
    assert_select "#store-footer-motto", "Uno más y listo."
    assert_no_match "Hecho con cuidado", response.body
  end

  test "con logo: el pie usa el mismo logo que el encabezado y conserva la información" do
    RetailCatalog::LogoUpload.attach(setting: @setting, file: image_upload("logo_transparent.png"))
    @setting.save!

    get store_root_path
    header_src = css_select("#store-brand-logo").first["src"]
    assert_select ".store-footer #store-footer-logo.store-footer-logo[alt='HANS Pastelería'][src=?]", header_src
    assert_select ".store-footer #store-footer-brand", count: 0
    assert_select ".store-footer .store-footer-steps li", 3
    assert_select ".store-footer a[href='https://wa.me/#{@setting.whatsapp_number}']"
    assert_select "#store-footer-motto", "Uno más y listo."
  end

  test "admin: sube un PNG transparente; el encabezado lo muestra optimizado en todas las páginas" do
    sign_in @admin
    get admin_retail_catalog_store_settings_path
    assert_select "#store-logo-empty"

    patch logo_admin_retail_catalog_store_settings_path, params: { logo: Rack::Test::UploadedFile.new(@transparent_logo.path, "image/png") }
    assert_redirected_to admin_retail_catalog_store_settings_path(anchor: "store-logo")
    @setting.reload
    assert @setting.logo.attached?
    assert_equal "image/png", @setting.logo.content_type
    assert_equal @admin, @setting.updated_by

    get admin_retail_catalog_store_settings_path
    assert_select "#store-logo-current[src*='/rails/active_storage/representations/proxy/']"

    [store_root_path, store_cart_path, store_product_path(id: @torta.id)].each do |path|
      get path
      assert_response :success
      assert_select "#store-brand-logo.store-brand-logo[alt='HANS Pastelería'][src*='/rails/active_storage/representations/proxy/']", 1, path
      assert_select "#store-brand .store-brand-name", 0, path
    end
    assert_select "#store-brand[aria-label='HANS Pastelería, inicio de la tienda']"
  end

  # La versión se genera con la MISMA configuración del modelo (named_variants[:header]), pero en un
  # proceso aparte: inicializar libvips dentro de un worker paralelo (fork) hace caer el proceso en
  # macOS y cuelga la suite. El resultado se inspecciona con vipsheader.
  test "la versión del logo conserva la transparencia y las proporciones" do
    transformations = RetailStoreSetting.attachment_reflections["logo"].named_variants[RetailStoreSetting::LOGO_VARIANT].transformations
    assert_equal :webp, transformations[:format]

    Dir.mktmpdir do |dir|
      source = @transparent_logo.path
      output = File.join(dir, "logo.webp")
      script = <<~RUBY
        require "json"
        require "image_processing/vips"
        t = JSON.parse(ARGV[2], symbolize_names: true)
        ImageProcessing::Vips.source(ARGV[0]).resize_to_limit(*t[:resize_to_limit]).convert(t[:format]).saver(**t[:saver]).call(destination: ARGV[1])
      RUBY
      ok = system("bundle", "exec", "ruby", "-e", script, source, output, transformations.to_json, chdir: Rails.root.to_s, out: File::NULL, err: File::NULL)
      skip "libvips no está disponible en este entorno" unless ok

      header = `vipsheader -a #{output.shellescape} 2>/dev/null`
      skip "vipsheader no está disponible en este entorno" if header.empty?
      assert_match(/^width: 200$/, header, "un logo chico no se agranda")
      assert_match(/^height: 80$/, header, "ni se deforma")
      assert_match(/^bands: 4$/, header, "el WebP conserva el canal de transparencia")
      max_alpha = `vips extract_band #{output.shellescape} #{File.join(dir, 'a.v').shellescape} 3 && vips max #{File.join(dir, 'a.v').shellescape} 2>/dev/null`.strip
      assert_equal 0.0, Float(max_alpha.split.first.to_s.tr(",", ".")), "los píxeles transparentes siguen transparentes"
    end
  end

  test "admin: acepta WebP, reemplaza el logo anterior y lo puede quitar" do
    sign_in @admin
    patch logo_admin_retail_catalog_store_settings_path, params: { logo: Rack::Test::UploadedFile.new(@transparent_logo.path, "image/png") }
    first_blob = @setting.reload.logo.blob

    patch logo_admin_retail_catalog_store_settings_path, params: { logo: image_upload("pixel.webp") }
    @setting.reload
    assert_not_equal first_blob.id, @setting.logo.blob.id
    assert_equal "image/webp", @setting.logo.content_type

    delete logo_admin_retail_catalog_store_settings_path
    assert_redirected_to admin_retail_catalog_store_settings_path(anchor: "store-logo")
    assert_not @setting.reload.logo.attached?

    get store_root_path
    assert_select "#store-brand-logo", count: 0
    assert_select "#store-brand .store-brand-name", "HANS"
  end

  test "admin: rechaza JPEG, archivos que no son imágenes, SVG, PDF y archivos de más de 5 MB" do
    sign_in @admin
    svg = Tempfile.new(["logo", ".svg"])
    svg.write(%(<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>))
    svg.rewind
    big = oversized_png

    [
      [image_upload("pixel.jpg"), /tiene que ser una imagen PNG o WebP/],
      [image_upload("not_an_image.jpg"), /tiene que ser una imagen PNG o WebP/],
      [Rack::Test::UploadedFile.new(svg.path, "image/svg+xml"), /tiene que ser una imagen PNG o WebP/],
      [image_upload("document.pdf"), /tiene que ser una imagen PNG o WebP/],
      [big, /supera el máximo de 5 MB/]
    ].each do |file, message|
      patch logo_admin_retail_catalog_store_settings_path, params: { logo: file }
      assert_response :unprocessable_entity
      assert_select "#store-logo", message
      assert_not @setting.reload.logo.attached?
    end

    patch logo_admin_retail_catalog_store_settings_path, params: {}
    assert_response :unprocessable_entity
    assert_select "#store-logo", /Elegí una imagen PNG o WebP/
  ensure
    svg&.close!
  end

  test "sin almacenamiento habilitado no se sube el logo" do
    RetailCatalog::PhotoStorage.stub(:enabled?, false) do
      result = RetailCatalog::LogoUpload.attach(setting: @setting, file: Rack::Test::UploadedFile.new(@transparent_logo.path, "image/png"))
      assert_not result.ok?
      assert_match "Cloudflare R2", result.error
    end
    assert_not @setting.reload.logo.attached?
  end

  test "solo administradores cambian el logo" do
    customer_user = User.create!(email: "logo-cust-#{rand(1_000_000)}@example.com", password: "password123", role: "customer", customer: @customer)
    cook = User.create!(email: "logo-cook-#{rand(1_000_000)}@example.com", password: "password123", role: "production")
    [customer_user, cook].each do |user|
      sign_in user
      patch logo_admin_retail_catalog_store_settings_path, params: { logo: Rack::Test::UploadedFile.new(@transparent_logo.path, "image/png") }
      delete logo_admin_retail_catalog_store_settings_path
      sign_out user
    end
    assert_not @setting.reload.logo.attached?
  end

  test "la vista previa (tienda cerrada) también muestra el logo y sin portada" do
    @setting.update!(published: false)
    RetailCatalog::LogoUpload.attach(setting: @setting, file: Rack::Test::UploadedFile.new(@transparent_logo.path, "image/png"))
    @setting.save!

    get store_root_path
    assert_select "#store-closed"
    assert_select "#store-brand-logo"

    sign_in @admin
    get store_root_path
    assert_select "#store-preview-bar"
    assert_select "#store-brand-logo"
    assert_select "#categorias-title"
    assert_select ".store-hero", count: 0
  end
end
