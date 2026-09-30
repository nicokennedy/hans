require "test_helper"

class Stock::RegisterAdjustmentTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(email: "register-adjustment-#{rand(1_000_000)}@example.com", password: "password123", role: "admin")
    raw = RawMaterial.create!(name: "RM RegisterAdjustment #{rand(1_000_000)}", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    preparation = Preparation.create!(name: "Prep RegisterAdjustment #{rand(1_000_000)}", yield_quantity: 1, yield_unit: "kg")
    preparation.recipe_components.create!(component: raw, quantity: 1, unit: "kg")
    @stock_item = StockItem.create!(stockable: preparation, active: true, quantity: 14, minimum_quantity: 2)
  end

  test "counting below the system's quantity logs a negative adjustment for the difference" do
    Stock::RegisterAdjustment.call(stock_item: @stock_item, counted_quantity: 13, user: @user, note: "Conteo de la tarde")

    @stock_item.reload
    assert_equal BigDecimal("13"), @stock_item.quantity

    movement = @stock_item.stock_movements.last
    assert_equal "adjustment", movement.movement_type
    assert_equal BigDecimal("-1"), movement.quantity
    assert_equal BigDecimal("13"), movement.resulting_quantity
    assert_equal @user, movement.user
    assert_equal "Conteo de la tarde", movement.note
  end

  test "counting above the system's quantity logs a positive adjustment" do
    Stock::RegisterAdjustment.call(stock_item: @stock_item, counted_quantity: 20, user: @user)

    @stock_item.reload
    assert_equal BigDecimal("20"), @stock_item.quantity
    assert_equal BigDecimal("6"), @stock_item.stock_movements.last.quantity
  end

  test "counting the same quantity as the system is a no-op — no movement logged" do
    Stock::RegisterAdjustment.call(stock_item: @stock_item, counted_quantity: 14, user: @user)

    assert_equal BigDecimal("14"), @stock_item.reload.quantity
    assert_equal 0, @stock_item.stock_movements.count
  end

  test "counting zero is allowed (stock ran out completely)" do
    Stock::RegisterAdjustment.call(stock_item: @stock_item, counted_quantity: 0, user: @user)

    assert_equal BigDecimal("0"), @stock_item.reload.quantity
  end

  test "raises for a negative counted quantity" do
    assert_raises(Stock::RegisterAdjustment::InvalidQuantityError) do
      Stock::RegisterAdjustment.call(stock_item: @stock_item, counted_quantity: -1, user: @user)
    end
    assert_equal BigDecimal("14"), @stock_item.reload.quantity
  end
end
