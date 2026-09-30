require "test_helper"

class Stock::RegisterProductionTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(email: "register-production-#{rand(1_000_000)}@example.com", password: "password123", role: "admin")
    raw = RawMaterial.create!(name: "RM RegisterProduction #{rand(1_000_000)}", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    preparation = Preparation.create!(name: "Prep RegisterProduction #{rand(1_000_000)}", yield_quantity: 1, yield_unit: "kg")
    preparation.recipe_components.create!(component: raw, quantity: 1, unit: "kg")
    @stock_item = StockItem.create!(stockable: preparation, active: true, quantity: 5, minimum_quantity: 2)
  end

  test "increases physical stock and logs a production movement with the user and note" do
    Stock::RegisterProduction.call(stock_item: @stock_item, quantity: 3, user: @user, note: "Horneada de la tarde")

    @stock_item.reload
    assert_equal BigDecimal("8"), @stock_item.quantity

    movement = @stock_item.stock_movements.last
    assert_equal "production", movement.movement_type
    assert_equal BigDecimal("3"), movement.quantity
    assert_equal BigDecimal("8"), movement.resulting_quantity
    assert_equal @user, movement.user
    assert_equal "Horneada de la tarde", movement.note
    assert_nil movement.order
  end

  test "raises for a zero quantity" do
    assert_raises(Stock::RegisterProduction::InvalidQuantityError) do
      Stock::RegisterProduction.call(stock_item: @stock_item, quantity: 0, user: @user)
    end
    assert_equal BigDecimal("5"), @stock_item.reload.quantity
  end

  test "raises for a negative quantity" do
    assert_raises(Stock::RegisterProduction::InvalidQuantityError) do
      Stock::RegisterProduction.call(stock_item: @stock_item, quantity: -1, user: @user)
    end
    assert_equal BigDecimal("5"), @stock_item.reload.quantity
  end

  test "works without a user or note" do
    Stock::RegisterProduction.call(stock_item: @stock_item, quantity: 1, user: nil)

    assert_equal BigDecimal("6"), @stock_item.reload.quantity
  end
end
