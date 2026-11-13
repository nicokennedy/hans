require "test_helper"
require_relative "../../support/retail_catalog_helpers"

# Importador del catálogo de TakePedido: agrupa tamaños en variantes, no duplica, simula por defecto y
# no toca productos existentes sin autorización.
class RetailCatalog::TakepedidoImportTest < ActiveSupport::TestCase
  include RetailCatalogHelpers

  CSV_PATH = Rails.root.join("test/fixtures/files/takepedido/muestra.csv")

  def importer
    RetailCatalog::TakepedidoImport.read(CSV_PATH)
  end

  def product(name)
    RetailProduct.includes(:variants).find_by!(name: name)
  end

  test "normaliza y agrupa: un producto por torta con sus tamaños; no mezcla productos distintos" do
    imp = importer
    names = imp.groups.map(&:name)
    assert_equal 17, imp.rows.size
    assert_includes names, "Cheesecake frutos rojos"
    tarta = imp.groups.select { |g| g.key == "tarta frutilla" }
    assert_equal 1, tarta.size, "Tarta frutilla / Tarta frutillas es un solo producto"
    assert_equal ["18 cm", "22 cm"], tarta.first.rows.map(&:size)
    assert_includes names, "Marquise mousse", "Marquise mousse / Marquise con mousse"
    cheese = imp.groups.find { |g| g.name == "Cheesecake frutos rojos" }
    assert_equal ["10 cm", "18 cm", "22 cm"], cheese.rows.map(&:size)
    assert_equal ["Caja x 6", "Caja x 12"], imp.groups.find { |g| g.name == "Macarons" }.rows.map(&:size)
    assert imp.groups.find { |g| g.name == "BOX HALLOWEEN" }.seasonal
    assert_equal "Base húmeda de nueces, dulce de leche y crema.\nOpcional frutillas $5000".squish, imp.groups.find { |g| g.name == "Torta nuez" }.description.squish
  end

  test "Box 12 y Box 30 vasitos se unifican en “Box de vasitos”; cada variante conserva su descripción" do
    importer.call(dry_run: false)
    box = product("Box de vasitos")
    assert_equal "Vasitos", box.retail_category.name
    assert_nil box.description
    assert_equal [["Box x 12", 3_360_000], ["Box x 30", 8_000_000]], box.variants.map { |v| [v.name, v.price_cents] }
    assert_match "Mínimo 4 por variedad", box.variants.first.description
    assert_match "Mínimo 5 variedades", box.variants.last.description
    assert_equal "Box x 30", box.display_variant.name
    assert_not RetailProduct.exists?(name: "Box 12")
  end

  test "simulación por defecto: no guarda nada" do
    counts = -> { [RetailProduct.count, RetailProductVariant.count, RetailCategory.count] }
    before = counts.call
    imp = importer.call
    assert_equal before, counts.call
    assert_equal 9, imp.summary[:created]
    assert_equal 9, imp.summary[:products]
  end

  test "importa: variantes con precio y disponibilidad propios, precio de catálogo del tamaño más grande disponible, sin duplicar" do
    importer.call(dry_run: false)
    nuez = product("Torta nuez")
    assert_equal [["18 cm", 3_800_000, true], ["22 cm", 4_600_000, true]], nuez.variants.map { |v| [v.name, v.price_cents, v.active] }
    assert_equal 4_600_000, nuez.price_cents
    assert nuez.active?

    tiramisu = product("Tiramisu")
    assert_equal [["10 cm", true], ["18 cm", false]], tiramisu.variants.map { |v| [v.name, v.active] }
    assert_equal "10 cm", tiramisu.display_variant.name, "el grande no está disponible"

    halloween = product("BOX HALLOWEEN")
    assert_not halloween.active?, "de temporada: oculto"
    assert_equal 16, halloween.variants.first.stock_quantity
    assert_equal "takepedido:ca9czx3deKxP8lLeAdI3", halloween.variants.first.external_ref
    assert_equal ["Caja x 6", "Caja x 12"], product("Macarons").variants.map(&:name)

    counts = [RetailProduct.count, RetailProductVariant.count]
    again = importer.call(dry_run: false)
    assert_equal counts, [RetailProduct.count, RetailProductVariant.count]
    assert_equal 0, again.summary[:created]
  end

  test "un producto existente no se modifica sin autorización; con ella conserva foto, nombre y código" do
    category = catalog_category("Tortas")
    existing = catalog_product("Torta de Nuez", category: category, price: "45.000", active: true)
    RetailCatalog::PhotoUpload.add(product: existing, files: [image_upload("pixel.png")])

    imp = importer.call(dry_run: false)
    action = imp.actions.find { |a| a.product == existing }
    assert_equal :needs_update, action.kind
    assert(action.details.any? { |d| d.include?("$45.000") && d.include?("$46.000") })
    assert_equal [nil], existing.reload.variants.map(&:name)
    assert_equal 4_500_000, existing.price_cents

    importer.call(dry_run: false, update_existing: true)
    existing.reload
    assert_equal ["18 cm", "22 cm"], existing.variants.map(&:name)
    assert_equal 4_600_000, existing.price_cents
    assert_equal ["Torta de Nuez", "TORTA-DE-NUEZ"], [existing.name, existing.code]
    assert existing.primary_photo
    assert_equal 1, RetailProduct.where("lower(name) LIKE 'torta%nuez'").count, "no se creó un duplicado"
  end
end
