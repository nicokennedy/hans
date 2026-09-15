require "test_helper"

class ProductTest < ActiveSupport::TestCase
  setup do
    @category = Category.create!(name: "Categoria cost_source", position: 1, active: true)
  end

  test "a new product defaults to cost_source manual, without setting it explicitly" do
    product = Product.create!(name: "Croissant especial", price_cents: 400_000, category: @category)

    assert product.manual?
    assert_equal "manual", product.cost_source
    assert_not product.recipe?
  end

  test "cost_source can be created without a known cost yet (manual, nil cost_cents)" do
    product = Product.new(name: "Croissant especial", price_cents: 400_000, category: @category)

    assert product.valid?
    assert_nil product.cost_cents
    assert product.manual?
  end

  test "cost_source is required and cannot be blank" do
    product = Product.new(name: "Sin cost_source", price_cents: 100, category: @category)
    product.cost_source = nil

    assert_not product.valid?
    assert product.errors[:cost_source].present?
  end

  test "cost_source only accepts the declared values (manual/recipe)" do
    product = Product.create!(name: "Alfajor cost_source", price_cents: 100, cost_cents: 50, category: @category)

    assert_raises(ArgumentError) { product.cost_source = "invented_value" }
  end

  test "a product can be explicitly created with cost_source recipe" do
    product = Product.create!(name: "Producto con receta", price_cents: 100, cost_cents: 50, category: @category, cost_source: "recipe")

    assert product.recipe?
    assert_not product.manual?
  end
end
