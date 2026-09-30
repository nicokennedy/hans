require "test_helper"

class StockItemTest < ActiveSupport::TestCase
  def build_preparation_stock_item(quantity: 3, minimum: 2, yield_unit: "kg")
    raw = RawMaterial.create!(name: "RM StockItem #{rand(1_000_000)}", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    preparation = Preparation.create!(name: "Prep StockItem #{rand(1_000_000)}", yield_quantity: 1, yield_unit: yield_unit)
    preparation.recipe_components.create!(component: raw, quantity: 1, unit: yield_unit)
    StockItem.create!(stockable: preparation, active: true, quantity: quantity, minimum_quantity: minimum)
  end

  def build_product_stock_item(quantity: 18, minimum: 20)
    category = Category.create!(name: "StockItemCat#{rand(1_000_000)}", position: 1, active: true)
    product = Product.create!(name: "Product StockItem #{rand(1_000_000)}", category: category, price_cents: 300, cost_cents: 100, active: true, position: 1)
    StockItem.create!(stockable: product, active: true, quantity: quantity, minimum_quantity: minimum)
  end

  test "unit is derived from the Preparation's yield_unit" do
    item = build_preparation_stock_item(yield_unit: "kg")
    assert_equal "kg", item.unit
  end

  test "unit is always 'un' for a Product" do
    item = build_product_stock_item
    assert_equal "un", item.unit
  end

  test "only one StockItem per stockable" do
    item = build_preparation_stock_item
    duplicate = StockItem.new(stockable: item.stockable, active: true, quantity: 0, minimum_quantity: 0)

    assert_not duplicate.valid?
  end

  test "apply_movement! increases quantity and logs a movement with the resulting balance" do
    item = build_preparation_stock_item(quantity: 3)

    movement = item.apply_movement!(movement_type: :production, quantity: 2)

    item.reload
    assert_equal BigDecimal("5"), item.quantity
    assert_equal BigDecimal("2"), movement.quantity
    assert_equal BigDecimal("5"), movement.resulting_quantity
    assert_equal "production", movement.movement_type
  end

  test "apply_movement! with a negative quantity decreases stock" do
    item = build_preparation_stock_item(quantity: 3)

    item.apply_movement!(movement_type: :dispatch, quantity: -1)

    assert_equal BigDecimal("2"), item.reload.quantity
  end

  test "apply_movement! with a zero quantity is a harmless no-op" do
    item = build_preparation_stock_item(quantity: 3)

    result = item.apply_movement!(movement_type: :adjustment, quantity: 0)

    assert_nil result
    assert_equal BigDecimal("3"), item.reload.quantity
    assert_equal 0, item.stock_movements.count
  end

  test "count! computes the delta against the current quantity and logs an adjustment" do
    item = build_preparation_stock_item(quantity: 5)

    movement = item.count!(counted_quantity: 3, user: nil)

    item.reload
    assert_equal BigDecimal("3"), item.quantity
    assert_equal BigDecimal("-2"), movement.quantity
    assert_equal BigDecimal("3"), movement.resulting_quantity
    assert_equal "adjustment", movement.movement_type
  end

  test "count! with the same value as the current quantity does nothing" do
    item = build_preparation_stock_item(quantity: 5)

    result = item.count!(counted_quantity: 5, user: nil)

    assert_nil result
    assert_equal 0, item.stock_movements.count
  end

  test "a StockItem with movements cannot be destroyed (traceability protected)" do
    item = build_preparation_stock_item(quantity: 3)
    item.apply_movement!(movement_type: :production, quantity: 1)

    assert_not item.destroy
    assert StockItem.exists?(item.id)
  end
end
