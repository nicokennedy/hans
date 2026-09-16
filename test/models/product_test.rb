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

  test "cost_cents cannot be changed through a normal update while cost_source is recipe" do
    product = Product.create!(name: "Producto receta protegido", price_cents: 100, cost_cents: 50, category: @category, cost_source: "recipe")

    product.cost_cents = 999
    assert_not product.valid?
    assert product.errors[:cost_cents].present?
    assert_not product.save
    assert_equal 50, product.reload.cost_cents
  end

  test "other fields of a recipe-sourced product remain editable through a normal update" do
    product = Product.create!(name: "Producto receta editable", price_cents: 100, cost_cents: 50, category: @category, cost_source: "recipe")

    assert product.update(name: "Nuevo nombre", price_cents: 200)
    product.reload
    assert_equal "Nuevo nombre", product.name
    assert_equal 200, product.price_cents
    assert_equal 50, product.cost_cents
  end

  test "activate_recipe_cost! bypasses the manual-edit protection, changing cost_source and cost_cents together" do
    product = Product.create!(name: "Producto para activar", price_cents: 100, cost_cents: 50, category: @category, cost_source: "manual")

    product.activate_recipe_cost!(12_345)
    product.reload

    assert product.recipe?
    assert_equal 12_345, product.cost_cents
  end

  test "sync_recipe_cost! bypasses the manual-edit protection to update cost_cents while already recipe-sourced" do
    product = Product.create!(name: "Producto para sync", price_cents: 100, cost_cents: 50, category: @category, cost_source: "recipe")

    product.sync_recipe_cost!(77_000)
    product.reload

    assert product.recipe?
    assert_equal 77_000, product.cost_cents
  end

  test "deactivate_recipe_cost! switches back to manual, preserving cost_cents unchanged" do
    product = Product.create!(name: "Producto para desactivar", price_cents: 100, cost_cents: 88_000, category: @category, cost_source: "recipe")

    product.deactivate_recipe_cost!
    product.reload

    assert product.manual?
    assert_equal 88_000, product.cost_cents
  end
end
