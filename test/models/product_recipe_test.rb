require "test_helper"

class ProductRecipeTest < ActiveSupport::TestCase
  def build_product(cost_source: "manual", cost_cents: 100_000)
    category = Category.create!(name: "PRModelCat#{rand(1_000_000)}", position: 1, active: true)
    Product.create!(name: "Producto PR Model #{rand(1_000_000)}", price_cents: 200_000,
      cost_cents: cost_cents, cost_source: cost_source, category: category, active: true, position: 1)
  end

  test "belongs to exactly one product, enforced by a unique index" do
    product = build_product
    ProductRecipe.create!(product: product, yield_quantity: 10)

    duplicate = ProductRecipe.new(product: product, yield_quantity: 5)
    assert_not duplicate.valid?
    assert duplicate.errors[:product_id].any?

    assert_raises(ActiveRecord::RecordNotUnique) do
      ActiveRecord::Base.transaction(requires_new: true) do
        ProductRecipe.insert!({ product_id: product.id, yield_quantity: 5, created_at: Time.current, updated_at: Time.current })
      end
    end
  end

  test "yield_quantity must be present and greater than 0" do
    product = build_product
    recipe = ProductRecipe.new(product: product, yield_quantity: nil)
    assert_not recipe.valid?

    recipe.yield_quantity = 0
    assert_not recipe.valid?

    recipe.yield_quantity = -1
    assert_not recipe.valid?

    recipe.yield_quantity = 12
    assert recipe.valid?
  end

  test "YIELD_UNIT is fixed and not a stored column" do
    assert_equal "un", ProductRecipe::YIELD_UNIT
    assert_not ProductRecipe.column_names.include?("yield_unit")
  end

  test "has no active column — governance is solely Product#cost_source" do
    assert_not ProductRecipe.column_names.include?("active")
  end

  test "calculable? requires yield_quantity > 0 and at least one component" do
    product = build_product
    recipe = ProductRecipe.create!(product: product, yield_quantity: 12)
    assert_not recipe.calculable?

    raw = RawMaterial.create!(name: "RM PR Model", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    recipe.recipe_components.create!(component: raw, quantity: 1, unit: "kg")

    assert recipe.calculable?
  end

  test "destroying the product destroys its ProductRecipe, but destroying the recipe never destroys the product" do
    product = build_product
    recipe = ProductRecipe.create!(product: product, yield_quantity: 12)

    recipe.destroy!
    assert Product.exists?(product.id)

    recipe2 = ProductRecipe.create!(product: product, yield_quantity: 12)
    product.destroy!
    assert_not ProductRecipe.exists?(recipe2.id)
  end
end
