require "test_helper"
require_relative "../../support/retail_catalog_helpers"

# Tienda Minorista → Productos / Categorías desde el administrador: CRUD, filtros, orden, fotos
# y permisos (solo admin, validado en el servidor).
class Admin::RetailCatalogTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include RetailCatalogHelpers

  setup do
    n = rand(1_000_000)
    @admin = User.create!(email: "catalog-admin-#{n}@example.com", password: "password123", role: "admin")
    @cook = User.create!(email: "catalog-cook-#{n}@example.com", password: "password123", role: "production")
    @wholesale_customer = Customer.create!(name: "Café #{n}", active: true)
    @customer_user = User.create!(email: "catalog-cust-#{n}@example.com", password: "password123", role: "customer", customer: @wholesale_customer)
    @category = catalog_category("Cookies")
    sign_in @admin
  end

  def listed_names
    css_select("a.retail-product-name").map { |a| a.text.strip }
  end

  # --- Categorías ---

  test "categorías: crear, editar, ver cuántos productos tiene, desactivar y reordenar" do
    get admin_retail_catalog_categories_path
    assert_response :success

    assert_difference "RetailCategory.count", 1 do
      post admin_retail_catalog_categories_path, params: { retail_category: { name: "Tortas", position: 2, active: "1" } }
    end
    tortas = RetailCategory.find_by!(name: "Tortas")
    assert_redirected_to admin_retail_catalog_categories_path

    patch admin_retail_catalog_category_path(tortas), params: { retail_category: { name: "Tortas y tartas" } }
    assert_equal "Tortas y tartas", tortas.reload.name

    post admin_retail_catalog_categories_path, params: { retail_category: { name: "cookies" } }
    assert_response :unprocessable_entity
    assert_select "#form-errors", text: /ya existe/
    assert_select "input[name='retail_category[name]'][value=?]", "cookies"

    catalog_product(category: @category)
    get admin_retail_catalog_categories_path
    assert_select "##{ActionView::RecordIdentifier.dom_id(@category)} td.text-end", text: "1"

    patch toggle_active_admin_retail_catalog_category_path(tortas)
    assert_not tortas.reload.active?

    patch move_up_admin_retail_catalog_category_path(tortas)
    assert_equal [tortas.id, @category.id], RetailCategory.ordered.pluck(:id)
  end

  test "categorías: no se elimina una con productos; sí una vacía" do
    catalog_product(category: @category)
    assert_no_difference "RetailCategory.count" do
      delete admin_retail_catalog_category_path(@category)
    end
    assert_match "tiene productos", flash[:alert]

    empty = catalog_category("Vacía")
    assert_difference "RetailCategory.count", -1 do
      delete admin_retail_catalog_category_path(empty)
    end
  end

  # --- Productos ---

  test "productos: crear con precio minorista y vínculo mayorista opcional" do
    wholesale = Product.create!(name: "Cookie mayorista", category: Category.create!(name: "May #{rand(1_000)}", position: 1, active: true), price_cents: 1_000, cost_cents: 500, active: true, position: 1)
    get new_admin_retail_catalog_product_path
    assert_response :success
    assert_select "select[name='retail_product[product_id]'] option", text: "Cookie mayorista"

    assert_difference "RetailProduct.count", 1 do
      post admin_retail_catalog_products_path, params: { retail_product: { name: "Box de cookies", price: "12.500", retail_category_id: @category.id, product_id: wholesale.id, description: "6 cookies", featured: "1", active: "0" } }
    end
    product = RetailProduct.last
    assert_redirected_to admin_retail_catalog_product_path(product)
    assert_equal [1_250_000, wholesale.id, true, false, "BOX-DE-COOKIES"], [product.price_cents, product.product_id, product.featured, product.active, product.code]
    assert_equal 1_000, wholesale.reload.price_cents

    follow_redirect!
    assert_select "#retail-product-data", text: /\$12\.500/
    assert_select "#retail-publication-issues", text: /Sin fotografía principal/
  end

  test "productos: un error de validación no pierde lo escrito" do
    post admin_retail_catalog_products_path, params: { retail_product: { name: "Torta", price: "abc", retail_category_id: @category.id, description: "Chocolate" } }

    assert_response :unprocessable_entity
    assert_select "#form-errors", text: /El precio no es un importe válido/
    assert_select "input[name='retail_product[name]'][value=?]", "Torta"
    assert_select "textarea[name='retail_product[description]']", text: "Chocolate"
    assert_equal 0, RetailProduct.count
  end

  test "productos: editar, activar/desactivar, duplicar y eliminar solo si está inactivo" do
    product = catalog_product("Brownie", category: @category, active: true)

    patch admin_retail_catalog_product_path(product), params: { retail_product: { price: "3.000", name: "Brownie XL" } }
    assert_equal ["Brownie XL", 300_000], product.reload.values_at(:name, :price_cents)

    assert_no_difference "RetailProduct.count" do
      delete admin_retail_catalog_product_path(product)
    end
    assert_match "Desactivá", flash[:alert]

    assert_difference "RetailProduct.count", 1 do
      post duplicate_admin_retail_catalog_product_path(product)
    end
    copy = RetailProduct.order(:id).last
    assert_redirected_to edit_admin_retail_catalog_product_path(copy)
    assert_equal "Brownie XL (copia)", copy.name

    patch toggle_active_admin_retail_catalog_product_path(product)
    assert_not product.reload.active?
    assert_difference "RetailProduct.count", -1 do
      delete admin_retail_catalog_product_path(product)
    end
  end

  test "productos: buscar por nombre o código, filtrar por categoría y estado, ordenar" do
    tortas = catalog_category("Tortas")
    catalog_product("Box de cookies", category: @category, price: "5.000", active: true, position: 2)
    catalog_product("Cookie suelta", category: @category, price: "800", active: false, position: 3)
    catalog_product("Torta de chocolate", category: tortas, price: "20.000", active: true, position: 1)

    get admin_retail_catalog_products_path
    assert_equal ["Torta de chocolate", "Box de cookies", "Cookie suelta"], listed_names
    assert_select "td", text: "$20.000"
    assert_select ".retail-photo-placeholder", count: 3

    get admin_retail_catalog_products_path, params: { q: "cookie" }
    assert_equal ["Box de cookies", "Cookie suelta"], listed_names
    get admin_retail_catalog_products_path, params: { q: "TORTA-DE" }
    assert_equal ["Torta de chocolate"], listed_names
    get admin_retail_catalog_products_path, params: { category_id: tortas.id }
    assert_equal ["Torta de chocolate"], listed_names
    get admin_retail_catalog_products_path, params: { status: "inactive" }
    assert_equal ["Cookie suelta"], listed_names
    get admin_retail_catalog_products_path, params: { status: "missing_photo", category_id: @category.id }
    assert_equal ["Box de cookies", "Cookie suelta"], listed_names
    get admin_retail_catalog_products_path, params: { sort: "price_desc" }
    assert_equal ["Torta de chocolate", "Box de cookies", "Cookie suelta"], listed_names
    get admin_retail_catalog_products_path, params: { sort: "name", category_id: "x; DROP", status: "<script>" }
    assert_equal ["Box de cookies", "Cookie suelta", "Torta de chocolate"], listed_names

    box = RetailProduct.find_by!(name: "Box de cookies")
    patch move_up_admin_retail_catalog_product_path(box)
    assert_equal ["Box de cookies", "Torta de chocolate", "Cookie suelta"], RetailProduct.ordered.pluck(:name)
  end

  # --- Fotos ---

  test "fotos: subir varias, elegir principal, ordenar, reemplazar y borrar desde el producto" do
    product = catalog_product(category: @category)

    post admin_retail_catalog_product_photos_path(product), params: { images: [image_upload("pixel.png"), image_upload("red.png"), image_upload("not_an_image.jpg")] }
    assert_redirected_to admin_retail_catalog_product_path(product, anchor: "fotos")
    assert_equal "2 fotos agregadas.", flash[:notice]
    assert_match "not_an_image.jpg: no es una imagen", flash[:alert]

    get admin_retail_catalog_product_path(product)
    assert_select "#retail-photos img", count: 2
    assert_select "#retail-photos .badge", text: "Principal", count: 1
    assert_select "#retail-photo-upload input[type=file][multiple][accept=?]", "image/jpeg,image/png,image/webp"

    second = product.photos.find_by(primary: false)
    patch make_primary_admin_retail_catalog_product_photo_path(product, second)
    assert second.reload.primary?

    patch admin_retail_catalog_product_photo_path(product, second), params: { image: image_upload("pixel.webp") }
    assert_equal "image/webp", second.reload.image.blob.content_type

    first = product.photos.find_by(primary: false)
    delete admin_retail_catalog_product_photo_path(product, first)
    delete admin_retail_catalog_product_photo_path(product, second)
    assert_match "única foto", flash[:alert]
    delete admin_retail_catalog_product_photo_path(product, second), params: { confirm_last: "1" }
    assert_empty product.photos.reload

    get admin_retail_catalog_products_path
    assert_select ".retail-photo-placeholder"
  end

  test "fotos: las miniaturas del listado usan la versión optimizada, no el original" do
    product = catalog_product(category: @category)
    RetailCatalog::PhotoUpload.add(product: product, files: [image_upload("pixel.png")])

    get admin_retail_catalog_products_path
    src = css_select("##{ActionView::RecordIdentifier.dom_id(product)} img").first["src"]
    assert_match "/rails/active_storage/representations/", src
  end

  test "fotos: sin almacenamiento habilitado no se ofrece la carga y el servidor la rechaza" do
    product = catalog_product(category: @category)
    RetailCatalog::PhotoStorage.stub(:enabled?, false) do
      get admin_retail_catalog_product_path(product)
      assert_select "#retail-photo-upload", count: 0
      assert_select "#retail-photo-upload-disabled"
      get admin_retail_catalog_products_path
      assert_select "#retail-photos-disabled", text: /Cloudflare R2/

      post admin_retail_catalog_product_photos_path(product), params: { images: [image_upload("pixel.png")] }
      assert_match "Cloudflare R2", flash[:alert]
    end
    assert_equal 0, product.photos.count
  end

  # --- Permisos ---

  test "solo administradores: clientes mayoristas, producción y anónimos no acceden a nada del catálogo" do
    product = catalog_product(category: @category)
    RetailCatalog::PhotoUpload.add(product: product, files: [image_upload("pixel.png")])
    photo = product.photos.first
    requests = [
      [:get, admin_retail_catalog_root_path], [:get, admin_retail_catalog_products_path], [:get, admin_retail_catalog_product_path(product)],
      [:get, new_admin_retail_catalog_product_path], [:get, edit_admin_retail_catalog_product_path(product)],
      [:post, admin_retail_catalog_products_path, { retail_product: { name: "X", price: "1", retail_category_id: @category.id } }],
      [:patch, admin_retail_catalog_product_path(product), { retail_product: { price: "1" } }],
      [:patch, toggle_active_admin_retail_catalog_product_path(product)], [:post, duplicate_admin_retail_catalog_product_path(product)],
      [:patch, move_up_admin_retail_catalog_product_path(product)], [:delete, admin_retail_catalog_product_path(product)],
      [:post, admin_retail_catalog_product_photos_path(product), { images: [image_upload("red.png")] }],
      [:patch, admin_retail_catalog_product_photo_path(product, photo), { image: image_upload("red.png") }],
      [:patch, make_primary_admin_retail_catalog_product_photo_path(product, photo)], [:delete, admin_retail_catalog_product_photo_path(product, photo), { confirm_last: "1" }],
      [:get, admin_retail_catalog_categories_path], [:post, admin_retail_catalog_categories_path, { retail_category: { name: "Hack" } }],
      [:patch, admin_retail_catalog_category_path(@category), { retail_category: { name: "Hack" } }], [:delete, admin_retail_catalog_category_path(catalog_category("Vacía"))]
    ]
    snapshot = -> { [RetailProduct.order(:id).pluck(:id, :name, :price_cents, :active, :updated_at), RetailCategory.order(:id).pluck(:id, :name, :active), RetailProductPhoto.order(:id).pluck(:id, :primary, :checksum)] }
    before = snapshot.call
    sign_out @admin

    [nil, @customer_user, @cook].each do |user|
      sign_in user if user
      requests.each do |verb, path, params|
        send(verb, path, params: params)
        assert_response :redirect, "#{verb} #{path} debería rechazarse (#{user&.role || 'anónimo'})"
        assert_no_match(/\$4\.500/, response.body)
      end
      sign_out user if user
    end
    assert_equal before, snapshot.call
  end

  test "el menú del administrador muestra Tienda Minorista solo al admin" do
    get admin_retail_orders_path
    assert_select "a[href=?]", admin_retail_catalog_products_path, text: "Tienda Minorista"
  end

  # --- Sin efectos sobre el resto ---

  test "usar el catálogo no toca productos, precios ni stock mayoristas, pedidos ni pagos" do
    wholesale = Product.create!(name: "Mayorista intacto", category: Category.create!(name: "Cat #{rand(1_000)}", position: 1, active: true), price_cents: 777, cost_cents: 300, active: true, position: 1)
    snapshot = -> { [Product.order(:id).pluck(:id, :price_cents, :cost_cents, :active, :updated_at), StockItem.count, StockMovement.count, Order.count, RetailOrder.count, Payment.count, RetailOrderPayment.count] }
    before = snapshot.call

    post admin_retail_catalog_products_path, params: { retail_product: { name: "Vinculado", price: "1.000", retail_category_id: @category.id, product_id: wholesale.id } }
    product = RetailProduct.last
    patch admin_retail_catalog_product_path(product), params: { retail_product: { price: "2.000" } }
    post duplicate_admin_retail_catalog_product_path(product)
    post admin_retail_catalog_product_photos_path(product), params: { images: [image_upload("pixel.png")] }
    get admin_retail_catalog_products_path

    assert_equal before, snapshot.call
  end
end
