require "test_helper"
require "csv"
require "tempfile"

class Products::CsvImporterTest < ActiveSupport::TestCase
  HEADERS = %w[id name category_name internal_category public_category price cost active position unit description].freeze

  setup do
    @category = Category.create!(name: "Alfajores", position: 1, active: true)
  end

  test "manual product existing: the CSV can update cost, same as before" do
    product = Product.create!(name: "Alfajor Manual", price_cents: 10_000, cost_cents: 4_000,
      category: @category, cost_source: "manual", active: true, position: 1)

    result = import([ product_row(name: "Alfajor Manual", cost: "50", price: "100") ])

    assert_equal 1, result.updated
    assert_empty result.errors
    assert_equal 5_000, product.reload.cost_cents
  end

  test "recipe product existing: the CSV does NOT update cost" do
    product = Product.create!(name: "Alfajor Receta", price_cents: 10_000, cost_cents: 4_000,
      category: @category, cost_source: "recipe", active: true, position: 1)

    result = import([ product_row(name: "Alfajor Receta", cost: "999", price: "100") ])

    assert_equal 1, result.updated
    assert_equal 4_000, product.reload.cost_cents
  end

  test "recipe product existing: the CSV DOES still update the other fields it manages" do
    other_category = Category.create!(name: "Budines", position: 2, active: true)
    product = Product.create!(name: "Alfajor Receta", price_cents: 10_000, cost_cents: 4_000,
      category: @category, cost_source: "recipe", internal_category: "AL", public_category: "Clasicos",
      active: true, position: 1, unit: "unidad", description: "vieja descripcion")

    result = import([
      product_row(name: "Alfajor Receta", cost: "999", price: "180", category_name: "Budines",
        internal_category: "BU", public_category: "Nuevos", active: "true", position: "3",
        unit: "docena", description: "nueva descripcion")
    ])

    assert_equal 1, result.updated
    product.reload
    assert_equal 18_000, product.price_cents
    assert_equal other_category, product.category
    assert_equal "BU", product.internal_category
    assert_equal "Nuevos", product.public_category
    assert_equal 3, product.position
    assert_equal "docena", product.unit
    assert_equal "nueva descripcion", product.description
    assert_equal 4_000, product.cost_cents, "cost must remain untouched"
  end

  test "new product: is born cost_source manual and takes the CSV cost normally" do
    result = import([ product_row(name: "Producto Nuevo Canonico", cost: "40", price: "100") ])

    assert_equal 1, result.created
    assert_empty result.errors

    product = Product.find_by!(name: "Producto Nuevo Canonico")
    assert product.manual?
    assert_equal 4_000, product.cost_cents
  end

  test "no regression: importing several rows still creates/updates/errors exactly as before" do
    existing = Product.create!(name: "Alfajor Existente", price_cents: 10_000, cost_cents: 4_000,
      category: @category, cost_source: "manual", active: true, position: 1)

    result = import([
      product_row(name: "Alfajor Existente", cost: "45", price: "110"),
      product_row(name: "Producto Canonico Nuevo", cost: "20", price: "60"),
      product_row(name: "", cost: "10", price: "10") # fila inválida: name en blanco
    ])

    assert_equal 1, result.created
    assert_equal 1, result.updated
    assert_equal 1, result.errors.size
    assert_match(/name no puede estar en blanco/, result.errors.first)

    assert_equal 11_000, existing.reload.price_cents
    assert_equal 4_500, existing.cost_cents
    assert Product.exists?(name: "Producto Canonico Nuevo")
  end

  private

  def product_row(name:, cost:, price:, category_name: "Alfajores", internal_category: "AL",
                   public_category: "Clasicos", active: "true", position: "1", unit: "unidad", description: "desc")
    { "id" => "", "name" => name, "category_name" => category_name, "internal_category" => internal_category,
      "public_category" => public_category, "price" => price, "cost" => cost, "active" => active,
      "position" => position, "unit" => unit, "description" => description }
  end

  def write_csv(rows)
    file = Tempfile.new([ "products_canonical_import", ".csv" ])
    CSV.open(file.path, "w") do |csv|
      csv << HEADERS
      rows.each { |row| csv << HEADERS.map { |h| row[h] } }
    end
    file.path
  end

  def import(rows)
    Products::CsvImporter.new(path: write_csv(rows)).call
  end
end
