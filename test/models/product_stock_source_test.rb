require "test_helper"

class ProductStockSourceTest < ActiveSupport::TestCase
  def setup
    category = Category.create!(name: "PSSCat#{rand(1_000_000)}", position: 1, active: true)
    @product = Product.create!(name: "Alfajor PSS #{rand(1_000_000)}", category: category, price_cents: 500, cost_cents: 200, active: true, position: 1)
    @tapas = Preparation.create!(name: "Tapas PSS #{rand(1_000_000)}", yield_quantity: 1, yield_unit: "un", stock_only: true)
  end

  test "links a product to a stock-only preparation, 1 unit per sale by default" do
    source = ProductStockSource.create!(product: @product, preparation: @tapas)

    assert_equal BigDecimal(1), source.quantity
    assert_equal [ @tapas ], @product.reload.product_stock_sources.map(&:preparation)
  end

  test "rejects a preparation that is a normal recipe preparation (only stock-only objects)" do
    masa = Preparation.create!(name: "Masa PSS #{rand(1_000_000)}", yield_quantity: 1, yield_unit: "kg")
    source = ProductStockSource.new(product: @product, preparation: masa)

    assert_not source.valid?
    assert source.errors[:preparation].present?
  end

  test "quantity must be positive" do
    [ 0, -1 ].each do |quantity|
      assert_not ProductStockSource.new(product: @product, preparation: @tapas, quantity: quantity).valid?
    end
  end

  test "a product cannot be linked twice to the same stock object" do
    ProductStockSource.create!(product: @product, preparation: @tapas)

    assert_not ProductStockSource.new(product: @product, preparation: @tapas).valid?
  end

  test "destroying the product removes its links, but a linked preparation cannot be destroyed" do
    ProductStockSource.create!(product: @product, preparation: @tapas)

    assert_not @tapas.destroy
    assert Preparation.exists?(@tapas.id)

    @product.destroy
    assert_equal 0, ProductStockSource.count
  end
end
