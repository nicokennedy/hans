require "test_helper"
require "csv"
require "tempfile"

class Products::AdminCsvImporterTest < ActiveSupport::TestCase
  setup do
    @category = Category.create!(name: "Alfajores", position: 1, active: true)
  end

  test "manual product: the CSV can update cost, same as before" do
    product = Product.create!(name: "Alfajor Manual", price_cents: 10_000, cost_cents: 4_000,
      category: @category, cost_source: "manual", internal_category: "AL", active: true, position: 1)

    result = import(apply: true) { csv_row(name: "Alfajor Manual", cost: "50", price: "100", category_code: "AL") }
    row = result.rows.first

    assert_equal :updated, row.status
    assert row.changes.any? { |c| c.start_with?("Costo:") }
    assert_equal 5_000, product.reload.cost_cents
  end

  test "manual product: the CSV can update price, same as before" do
    product = Product.create!(name: "Alfajor Manual", price_cents: 10_000, cost_cents: 4_000,
      category: @category, cost_source: "manual", internal_category: "AL", active: true, position: 1)

    result = import(apply: true) { csv_row(name: "Alfajor Manual", cost: "40", price: "150", category_code: "AL") }
    row = result.rows.first

    assert_equal :updated, row.status
    assert row.changes.any? { |c| c.start_with?("Precio:") }
    assert_equal 15_000, product.reload.price_cents
  end

  test "recipe product: the CSV does NOT modify cost_cents, even in apply mode" do
    product = Product.create!(name: "Alfajor Receta", price_cents: 10_000, cost_cents: 4_000,
      category: @category, cost_source: "recipe", internal_category: "AL", active: true, position: 1)

    import(apply: true) { csv_row(name: "Alfajor Receta", cost: "999", price: "100", category_code: "AL") }

    assert_equal 4_000, product.reload.cost_cents
  end

  test "recipe product: the CSV DOES update price_cents" do
    product = Product.create!(name: "Alfajor Receta", price_cents: 10_000, cost_cents: 4_000,
      category: @category, cost_source: "recipe", internal_category: "AL", active: true, position: 1)

    result = import(apply: true) { csv_row(name: "Alfajor Receta", cost: "999", price: "180", category_code: "AL") }
    row = result.rows.first

    assert_equal :updated, row.status
    assert_equal 18_000, product.reload.price_cents
  end

  test "recipe product: the CSV DOES update other fields the importer already manages (client/internal category)" do
    product = Product.create!(name: "Alfajor Receta", price_cents: 10_000, cost_cents: 4_000,
      category: @category, cost_source: "recipe", internal_category: "AL", active: true, position: 1)

    result = import(apply: true) { csv_row(name: "Alfajor Receta", cost: "999", price: "100", category_code: "BU") }
    row = result.rows.first

    assert_equal :updated, row.status
    product.reload
    assert_equal "Budines", product.category.name
    assert_equal "BU", product.internal_category
  end

  test "recipe product whose only CSV difference is cost: stays :unchanged and cost is left untouched" do
    product = Product.create!(name: "Alfajor Receta", price_cents: 10_000, cost_cents: 4_000,
      category: @category, cost_source: "recipe", internal_category: "AL", active: true, position: 1)

    result = import(apply: true) { csv_row(name: "Alfajor Receta", cost: "999", price: "100", category_code: "AL") }
    row = result.rows.first

    assert_equal :unchanged, row.status
    assert_equal [], row.changes
    assert_equal 4_000, product.reload.cost_cents
    assert_equal 10_000, product.price_cents
  end

  test "preview shows the 'Costo ignorado' notice for a recipe product whose CSV brings a cost" do
    Product.create!(name: "Alfajor Receta", price_cents: 10_000, cost_cents: 4_000,
      category: @category, cost_source: "recipe", internal_category: "AL", active: true, position: 1)

    result = import(apply: false) { csv_row(name: "Alfajor Receta", cost: "999", price: "100", category_code: "AL") }
    row = result.rows.first

    assert_includes row.notices, "Costo ignorado: producto con costo calculado por receta"
  end

  test "preview does NOT show the notice for a manual product, or when the CSV brings no cost at all" do
    manual_product = Product.create!(name: "Alfajor Manual", price_cents: 10_000, cost_cents: 4_000,
      category: @category, cost_source: "manual", internal_category: "AL", active: true, position: 1)
    recipe_product = Product.create!(name: "Alfajor Receta Sin Costo CSV", price_cents: 10_000, cost_cents: 4_000,
      category: @category, cost_source: "recipe", internal_category: "AL", active: true, position: 2)

    result = import(apply: false) do
      [
        csv_row(name: "Alfajor Manual", cost: "50", price: "100", category_code: "AL"),
        csv_row(name: "Alfajor Receta Sin Costo CSV", cost: "", price: "100", category_code: "AL")
      ]
    end

    manual_row = result.rows.find { |r| r.name == "Alfajor Manual" }
    recipe_row_no_cost = result.rows.find { |r| r.name == "Alfajor Receta Sin Costo CSV" }

    assert_equal [], Array(manual_row.notices)
    assert_equal [], Array(recipe_row_no_cost.notices)
  end

  test "a new product imported by the CSV is born with cost_source manual" do
    result = import(apply: true) { csv_row(name: "Producto Nuevo Import", cost: "40", price: "100", category_code: "AL") }
    row = result.rows.first

    assert_equal :new, row.status
    product = Product.find_by!(name: "Producto Nuevo Import")
    assert product.manual?
    assert_equal 4_000, product.cost_cents
  end

  test "preview (apply: false) and apply (apply: true) classify the same CSV identically, and preview never writes" do
    product = Product.create!(name: "Alfajor Receta", price_cents: 10_000, cost_cents: 4_000,
      category: @category, cost_source: "recipe", internal_category: "AL", active: true, position: 1)

    path = write_csv([ csv_row(name: "Alfajor Receta", cost: "999", price: "150", category_code: "AL") ])

    preview_result = Products::AdminCsvImporter.new(path: path, apply: false).call
    assert_equal :updated, preview_result.rows.first.status
    assert_equal 10_000, product.reload.price_cents, "preview must not write anything"
    assert_equal 4_000, product.cost_cents, "preview must not write anything"

    apply_result = Products::AdminCsvImporter.new(path: path, apply: true).call
    assert_equal :updated, apply_result.rows.first.status
    assert_equal 15_000, product.reload.price_cents
    assert_equal 4_000, product.cost_cents, "cost stays untouched even on apply, because the product is recipe-sourced"
  end

  test "no regression: a manual product with multiple real changes (price, cost, categories) still updates everything at once" do
    product = Product.create!(name: "Alfajor Multi Cambio", price_cents: 10_000, cost_cents: 4_000,
      category: @category, cost_source: "manual", internal_category: "AL", active: true, position: 1)

    result = import(apply: true) { csv_row(name: "Alfajor Multi Cambio", cost: "60", price: "200", category_code: "BU") }
    row = result.rows.first

    assert_equal :updated, row.status
    assert_equal 4, row.changes.size # precio, costo, categoría cliente, categoría interna
    product.reload
    assert_equal 20_000, product.price_cents
    assert_equal 6_000, product.cost_cents
    assert_equal "Budines", product.category.name
    assert_equal "BU", product.internal_category
  end

  private

  def csv_row(name:, cost:, price:, category_code:)
    [ name, cost, price, category_code ]
  end

  def write_csv(rows)
    file = Tempfile.new([ "admin_products_import", ".csv" ])
    CSV.open(file.path, "w") do |csv|
      csv << [ "NOMBRE", "COSTO X U", "PRECIO MAY", "Categoría" ]
      rows.each { |row| csv << row }
    end
    file.path
  end

  def import(apply:, &block)
    rows = block.call
    rows = [ rows ] if rows.first.is_a?(String)
    path = write_csv(rows)
    Products::AdminCsvImporter.new(path: path, apply: apply).call
  end
end
