require "test_helper"

class StockMovementTest < ActiveSupport::TestCase
  def build_stock_item(quantity: 5)
    raw = RawMaterial.create!(name: "RM Movement #{rand(1_000_000)}", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    preparation = Preparation.create!(name: "Prep Movement #{rand(1_000_000)}", yield_quantity: 1, yield_unit: "kg")
    preparation.recipe_components.create!(component: raw, quantity: 1, unit: "kg")
    StockItem.create!(stock_tracking_started_on: Date.new(2026, 1, 1), stockable: preparation, active: true, quantity: quantity, minimum_quantity: 1)
  end

  test "quantity cannot be zero" do
    item = build_stock_item
    movement = StockMovement.new(stock_item: item, movement_type: :adjustment, quantity: 0, resulting_quantity: 5)

    assert_not movement.valid?
  end

  test "quantity can be negative (a dispatch) or positive (a production)" do
    item = build_stock_item

    negative = StockMovement.new(stock_item: item, movement_type: :dispatch, quantity: -2, resulting_quantity: 3)
    positive = StockMovement.new(stock_item: item, movement_type: :production, quantity: 2, resulting_quantity: 7)

    assert negative.valid?
    assert positive.valid?
  end

  test "movement_type must be one of the defined types" do
    item = build_stock_item

    assert_raises(ArgumentError) do
      StockMovement.new(stock_item: item, movement_type: :nonsense, quantity: 1, resulting_quantity: 6)
    end
  end

  test "order and user are optional" do
    item = build_stock_item
    movement = StockMovement.new(stock_item: item, movement_type: :adjustment, quantity: 1, resulting_quantity: 6)

    assert movement.valid?
  end

  test "a persisted movement is readonly and cannot be updated" do
    item = build_stock_item
    movement = item.apply_movement!(movement_type: :production, quantity: 1)

    assert_raises(ActiveRecord::ReadOnlyRecord) do
      movement.update!(quantity: 5)
    end
  end

  test "a persisted movement cannot be destroyed" do
    item = build_stock_item
    movement = item.apply_movement!(movement_type: :production, quantity: 1)

    assert_raises(ActiveRecord::ReadOnlyRecord) do
      movement.destroy!
    end
  end

  test "a new (unpersisted) movement is not readonly" do
    item = build_stock_item
    movement = StockMovement.new(stock_item: item, movement_type: :adjustment, quantity: 1, resulting_quantity: 6)

    assert_not movement.readonly?
  end
end
