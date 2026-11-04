require "test_helper"
require_relative "../support/retail_catalog_helpers"

# Modelos del catálogo minorista: categorías, productos, precio propio, código interno,
# duplicación, preparación para publicar y vínculo opcional con el catálogo mayorista.
class RetailCatalogTest < ActiveSupport::TestCase
  include RetailCatalogHelpers

  test "categoría: nombre obligatorio y único sin importar mayúsculas" do
    catalog_category("Tortas")
    duplicate = RetailCategory.new(name: "  tortas ")
    assert_not duplicate.valid?
    assert_includes duplicate.errors.full_messages, "El nombre ya existe"
    assert_not RetailCategory.new(name: "").valid?
  end

  test "categoría con productos no se borra: deja la referencia consistente" do
    category = catalog_category
    catalog_product(category: category)

    assert_not category.deletable?
    assert_not category.destroy
    assert RetailCategory.exists?(category.id)
    assert_raises(ActiveRecord::InvalidForeignKey) { RetailCategory.where(id: category.id).delete_all }
  end

  test "precio minorista: obligatorio, en pesos, mayor o igual a cero" do
    category = catalog_category
    assert_equal 450_000, catalog_product(category: category, price: "4.500").price_cents
    assert_equal 0, catalog_product(category: category, price: "0").price_cents
    assert_equal 125_050, catalog_product(category: category, price: "1.250,50").price_cents

    { "" => "El precio es obligatorio", "abc" => "El precio no es un importe válido", "-10" => "El precio no es un importe válido" }.each do |input, message|
      product = RetailProduct.new(name: "X", retail_category: category, price: input)
      assert_not product.valid?, "debería rechazar #{input.inspect}"
      assert_includes product.errors.full_messages, message
    end
    assert_raises(ActiveRecord::StatementInvalid) { RetailProduct.where(id: catalog_product(category: category).id).update_all(price_cents: -1) }
  end

  test "código interno: se genera desde el nombre, es único y se puede escribir" do
    category = catalog_category
    a = catalog_product("Box de Cookies Ñandú", category: category)
    b = catalog_product("Box de cookies ñandú", category: category)
    assert_equal "BOX-DE-COOKIES-NANDU", a.code
    assert_equal "BOX-DE-COOKIES-NANDU-2", b.code

    c = catalog_product("Otro", category: category, code: "mi codigo 1")
    assert_equal "MI-CODIGO-1", c.code
    repeated = RetailProduct.new(name: "Y", retail_category: category, price: "1", code: "mi-codigo-1")
    assert_not repeated.valid?
    assert_includes repeated.errors.full_messages, "El código interno ya lo usa otro producto"
  end

  test "activo/inactivo, destacado y listo para publicar (activo, categoría activa y foto principal)" do
    product = catalog_product(active: false)
    assert_equal ["Inactivo", "Sin fotografía principal"], product.publication_issues
    assert_not product.featured?

    product.update!(active: true, featured: true)
    product.retail_category.update!(active: false)
    assert_equal ["Categoría inactiva", "Sin fotografía principal"], product.reload.publication_issues

    product.retail_category.update!(active: true)
    photo = product.photos.new(checksum: "abc", primary: true)
    photo.image.attach(io: File.open(FILES.join("pixel.png")), filename: "pixel.png", content_type: "image/png")
    photo.save!
    assert product.reload.ready_for_store?
  end

  test "duplicar: copia datos con código nuevo, inactiva y sin fotos" do
    wholesale = Product.create!(name: "Cookie mayorista #{rand(1_000)}", category: Category.create!(name: "Cat #{rand(1_000)}", position: 1, active: true), price_cents: 100, cost_cents: 50, active: true, position: 1)
    original = catalog_product("Box", description: "Rico", active: true, featured: true, product: wholesale)
    copy = original.duplicate
    copy.save!

    assert_equal "Box (copia)", copy.name
    assert_equal [original.price_cents, original.description, original.retail_category_id, wholesale.id], [copy.price_cents, copy.description, copy.retail_category_id, copy.product_id]
    assert_not_equal original.code, copy.code
    assert_not copy.active?
    assert_not copy.featured?
    assert_empty copy.photos
  end

  test "vínculo mayorista opcional: no modifica el producto mayorista y se limpia solo si ese producto se borra" do
    category = Category.create!(name: "Mayorista #{rand(1_000)}", position: 1, active: true)
    wholesale = Product.create!(name: "Alfajor #{rand(1_000)}", category: category, price_cents: 30_000, cost_cents: 10_000, active: true, position: 1)
    before = wholesale.reload.attributes

    special = catalog_product("Especial")
    assert_nil special.product
    linked = catalog_product("Box alfajores", price: "9.999", product: wholesale)

    assert_equal before, wholesale.reload.attributes, "el producto mayorista no cambia"
    assert_equal 999_900, linked.price_cents
    wholesale.update!(price_cents: 50_000)
    assert_equal 999_900, linked.reload.price_cents, "el precio minorista no sigue al mayorista"

    wholesale.destroy!
    assert_nil linked.reload.product_id
    assert RetailProduct.exists?(linked.id)
  end

  test "las fotos usan versiones optimizadas en WebP, nunca el original" do
    variants = RetailProductPhoto.reflect_on_attachment(:image).named_variants
    assert_equal %i[thumb card detail].sort, variants.keys.sort
    variants.each_value { |v| assert_equal :webp, v.transformations[:format] }
    assert_equal [600, 600], variants[:card].transformations[:resize_to_fill]
  end

  test "sin credenciales R2: en desarrollo y test se usa disco local y HANS arranca" do
    assert RetailCatalog::PhotoStorage.enabled?
    assert_equal :test, RetailCatalog::PhotoStorage.current_service_name
    error = assert_raises(ArgumentError) { RetailCatalog::PhotoStorage.check_r2! }
    assert_match "R2_BUCKET", error.message
  end

  test "en producción sin R2 las fotos quedan bloqueadas y se explica qué falta" do
    Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new("production")) do
      assert_not RetailCatalog::PhotoStorage.enabled?
      assert_match "Faltan variables de Cloudflare R2", RetailCatalog::PhotoStorage.blockers.first
    end
  end
end
