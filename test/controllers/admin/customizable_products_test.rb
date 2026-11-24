require "test_helper"
require_relative "../../support/retail_helpers"
require_relative "../../support/retail_catalog_helpers"
require_relative "../../support/box_helpers"

# Administrador: "Permitir personalizar el contenido", unidades por variante y sabores (Etapa 2).
class Admin::CustomizableProductsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include RetailHelpers
  include RetailCatalogHelpers
  include BoxHelpers

  setup do
    setup_retail
    @cajitas = catalog_category("Cajitas #{rand(1_000_000)}", active: true)
    sign_in @admin
  end

  def product_params(overrides = {})
    { name: "Mix de alfajores", retail_category_id: @cajitas.id, active: "1", customizable_content: "1",
      variants_attributes: {
        "0" => { name: "Caja x 8", position: "1", price: "8.000", content_units: "8", active: "1", stock_mode: "unlimited" },
        "1" => { name: "Caja x 24", position: "2", price: "20.000", content_units: "24", active: "1", stock_mode: "unlimited" }
      },
      flavors_attributes: { "0" => { name: "Almendra", position: "1", active: "1" }, "1" => { name: "Maicena", position: "2", active: "1" },
                            "2" => { name: "", position: "3", active: "1" } } }.deep_merge(overrides)
  end

  test "el formulario ofrece la opción, las unidades por variante y los sabores" do
    get new_admin_retail_catalog_product_path
    assert_response :success
    assert_select "#retail-customizable input[type=checkbox][name='retail_product[customizable_content]']"
    assert_select "#retail-flavors template"
    assert_select "#retail-variants input[name$='[content_units]']"
  end

  test "crear: unidades explícitas por variante y sabores en orden (las filas vacías se ignoran)" do
    assert_difference({ "RetailProduct.count" => 1, "RetailProductFlavor.count" => 2 }) do
      post admin_retail_catalog_products_path, params: { retail_product: product_params }
    end
    product = RetailProduct.order(:id).last
    assert product.customizable_content?
    assert_equal [8, 24], product.ordered_variants.map(&:content_units)
    assert_equal %w[Almendra Maicena], product.ordered_flavors.map(&:name)

    get admin_retail_catalog_product_path(product)
    assert_select "#retail-product-flavors", /Almendra/
    assert_select "#retail-product-variants", /24/
  end

  test "con personalización, cada variante habilitada necesita unidades (1 a 200) y hay que tener sabores" do
    post admin_retail_catalog_products_path, params: { retail_product: product_params(variants_attributes: { "1" => { content_units: "" } }) }
    assert_response :unprocessable_entity
    assert_match "falta en: Caja x 24", response.body

    post admin_retail_catalog_products_path, params: { retail_product: product_params(variants_attributes: { "1" => { content_units: "201" } }) }
    assert_response :unprocessable_entity
    assert_match "1 a 200", response.body

    post admin_retail_catalog_products_path, params: { retail_product: product_params(flavors_attributes: { "0" => { active: "0" }, "1" => { active: "0" } }) }
    assert_response :unprocessable_entity
    assert_match "al menos un sabor habilitado", response.body

    post admin_retail_catalog_products_path, params: { retail_product: product_params(flavors_attributes: { "1" => { name: "almendra" } }) }
    assert_response :unprocessable_entity
    assert_match "sabores con el mismo nombre", response.body
  end

  test "editar sabores: renombrar, ordenar, deshabilitar; uno usado en pedidos no se borra" do
    mix = create_mix_box(category: @cajitas)
    almendra, maicena, cacao = mix.ordered_flavors
    patch admin_retail_catalog_product_path(mix), params: { retail_product: { flavors_attributes: {
      "0" => { id: almendra.id, name: "Almendra glaseada", position: "9" },
      "1" => { id: cacao.id, active: "0" },
      "2" => { id: maicena.id, _destroy: "1" }
    } } }
    assert_redirected_to admin_retail_catalog_product_path(mix)
    mix.reload
    assert_equal ["Cacao", "Almendra glaseada"], mix.ordered_flavors.map(&:name)
    assert_not mix.flavors.find_by(name: "Cacao").active?

    snapshot = Retail::BoxComposition.validate(variant: box_variant(mix, 8), quantities: { almendra.id => 8 }).snapshot
    Retail::SaveOrder.call(order: RetailOrder.new, attributes: base_attributes, user: @admin,
      items: [{ "kind" => "box", "retail_product_variant_id" => box_variant(mix, 8).id.to_s, "quantity" => "1", "unit_price" => "8000",
                "composition" => { almendra.id.to_s => "8" } }]).then { |r| assert r.ok?, r.errors.inspect }
    assert_equal snapshot["flavors"].first["id"], almendra.id
    assert almendra.reload.used_in_orders?

    patch admin_retail_catalog_product_path(mix), params: { retail_product: { flavors_attributes: { "0" => { id: almendra.id, _destroy: "1" } } } }
    assert_response :unprocessable_entity
    assert_match "no se elimina: deshabilitalo", response.body
    assert RetailProductFlavor.exists?(almendra.id)
  end

  test "la tienda no muestra un producto personalizable sin sabores habilitados; el resto no cambia" do
    mix = create_mix_box(category: @cajitas)
    simple = catalog_product("Box de cookies", category: @cajitas, active: true)
    RetailCatalog::PhotoUpload.add(product: simple, files: [image_upload("pixel.png")])
    assert_includes RetailProduct.for_store, mix
    assert_includes RetailProduct.for_store, simple

    mix.flavors.update_all(active: false)
    assert_not_includes RetailProduct.for_store, mix
    assert_includes RetailProduct.for_store, simple
    assert_includes mix.reload.publication_issues, "Sin sabores habilitados"
    assert_not simple.reload.customizable_content?, "los productos existentes no cambian"
  end

  test "duplicar copia unidades y sabores" do
    mix = create_mix_box(category: @cajitas)
    copy = mix.duplicate
    copy.save!
    assert copy.customizable_content?
    assert_equal [8, 12, 24], copy.ordered_variants.map(&:content_units)
    assert_equal %w[Almendra Maicena Cacao], copy.ordered_flavors.map(&:name)
  end
end
