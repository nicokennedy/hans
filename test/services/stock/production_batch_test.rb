require "test_helper"

# Lote de producción (StockItem#production_batch_size): solo RECOMIENDA cuántas
# tandas preparar a partir del faltante que Availability ya calcula
# (production_needed). No recalcula físico, compromisos ni mínimo, y nunca
# limita lo que se registra.
class Stock::ProductionBatchTest < ActiveSupport::TestCase
  def setup
    @category = Category.create!(name: "BatchCat#{rand(1_000_000)}", position: 1, active: true)
    @customer = Customer.create!(name: "Cliente Batch #{rand(1_000_000)}", active: true)
    @user = User.create!(email: "batch-#{rand(1_000_000)}@example.com", password: "password123", role: "admin")
    @product = Product.create!(name: "Producto Batch #{rand(1_000_000)}", category: @category, price_cents: 500, cost_cents: 200, active: true, position: 1)
  end

  def item(physical:, minimum:, batch: nil, stockable: @product)
    StockItem.create!(stockable: stockable, active: true, quantity: physical, minimum_quantity: minimum, production_batch_size: batch)
  end

  def snapshot(stock_item)
    Stock::Availability.for_item(stock_item)
  end

  test "faltan 5 con lote 22 -> 1 tanda / 22 sugeridas (el faltante sigue siendo 5)" do
    s = snapshot(item(physical: 15, minimum: 20, batch: 22))

    assert_equal BigDecimal(5), s.production_needed
    assert_equal 1, s.production_batches_needed
    assert_equal BigDecimal(22), s.production_suggested
    assert_equal BigDecimal(22), s.production_batch_size
  end

  test "faltan 22 con lote 22 -> 1 tanda / 22" do
    s = snapshot(item(physical: 0, minimum: 22, batch: 22))

    assert_equal 1, s.production_batches_needed
    assert_equal BigDecimal(22), s.production_suggested
  end

  test "faltan 23 con lote 22 -> 2 tandas / 44" do
    s = snapshot(item(physical: 0, minimum: 23, batch: 22))

    assert_equal BigDecimal(23), s.production_needed
    assert_equal 2, s.production_batches_needed
    assert_equal BigDecimal(44), s.production_suggested
  end

  test "faltan 30 con lote 22 -> 2 tandas / 44" do
    s = snapshot(item(physical: 0, minimum: 30, batch: 22))

    assert_equal 2, s.production_batches_needed
    assert_equal BigDecimal(44), s.production_suggested
  end

  test "un faltante fraccionario también pide una tanda completa" do
    s = snapshot(item(physical: BigDecimal("19.9"), minimum: 20, batch: 22))

    assert_equal 1, s.production_batches_needed
  end

  test "faltante 0 -> no sugiere tandas" do
    [ 20, 35 ].each do |physical|
      StockItem.where(stockable: @product).destroy_all
      s = snapshot(item(physical: physical, minimum: 20, batch: 22))

      assert_equal BigDecimal(0), s.production_needed
      assert_equal 0, s.production_batches_needed
      assert_equal BigDecimal(0), s.production_suggested
    end
  end

  test "sin production_batch_size se mantiene el comportamiento actual (sin tandas)" do
    s = snapshot(item(physical: 15, minimum: 20))

    assert_equal BigDecimal(5), s.production_needed
    assert_nil s.production_batch_size
    assert_nil s.production_batches_needed
    assert_nil s.production_suggested
  end

  test "el lote no cambia ninguno de los demás valores del snapshot" do
    without_batch = snapshot(item(physical: 15, minimum: 20))
    StockItem.where(stockable: @product).destroy_all
    with_batch = snapshot(item(physical: 15, minimum: 20, batch: 22))

    %i[physical_quantity future_committed today_dispatch available_quantity minimum_quantity production_needed status].each do |field|
      assert_equal without_batch[field], with_batch[field], "#{field} no debería cambiar con el lote"
    end
  end

  test "un StockItem de pool stock_only con lote calcula el faltante desde el disponible (con compromisos) y redondea a tandas" do
    tapas = Preparation.create!(name: "Tapas Batch #{rand(1_000_000)}", yield_quantity: 1, yield_unit: "un", stock_only: true)
    ProductStockSource.create!(product: @product, preparation: tapas)
    pool = item(physical: 30, minimum: 20, batch: 22, stockable: tapas)

    order = Order.new(customer: @customer, delivery_date: Date.current + 7, created_by_admin: true, payment_method_selected: "cash_on_delivery")
    order.order_items.build(product: @product, quantity: 15)
    order.save!

    s = snapshot(pool)

    assert_equal BigDecimal(15), s.future_committed
    assert_equal BigDecimal(15), s.available_quantity # 30 - 15
    assert_equal BigDecimal(5), s.production_needed # 20 - 15
    assert_equal 1, s.production_batches_needed
    assert_equal BigDecimal(22), s.production_suggested
    assert_equal "un", s.unit
  end

  test "el lote no altera consumo, vínculos, físico ni compromisos" do
    tapas = Preparation.create!(name: "Tapas Batch2 #{rand(1_000_000)}", yield_quantity: 1, yield_unit: "un", stock_only: true)
    source = ProductStockSource.create!(product: @product, preparation: tapas)
    pool = item(physical: 30, minimum: 20, stockable: tapas)

    consumption_before = Stock::ProductConsumption.call(@product).to_h
    sources_before = ProductStockSource.pluck(:id, :product_id, :preparation_id, :quantity)

    pool.update!(production_batch_size: 22)

    assert_equal consumption_before, Stock::ProductConsumption.call(@product).to_h
    assert_equal sources_before, ProductStockSource.pluck(:id, :product_id, :preparation_id, :quantity)
    assert_equal BigDecimal(30), pool.reload.quantity
    assert_equal 0, StockMovement.count
    assert_equal BigDecimal(1), source.reload.quantity
  end

  test "el lote no cambia el descuento físico (dispatch)" do
    pool = item(physical: 30, minimum: 20, batch: 22)
    order = nil
    travel_to(Time.zone.local(2026, 10, 6, 9, 0, 0)) do
      order = Order.new(customer: @customer, delivery_date: Date.new(2026, 10, 6), created_by_admin: true, payment_method_selected: "cash_on_delivery")
      order.order_items.build(product: @product, quantity: 4)
      order.save!
    end

    travel_to Time.zone.local(2026, 10, 6, 14, 0, 0) do
      Stock::DispatchReconciler.call(order)
      s = snapshot(pool)
      assert_equal BigDecimal(26), pool.reload.quantity
      assert_equal BigDecimal(26), s.physical_quantity
    end
  end

  test "se puede registrar una producción distinta al lote (el lote es solo una recomendación)" do
    pool = item(physical: 15, minimum: 20, batch: 22)

    Stock::RegisterProduction.call(stock_item: pool, quantity: 20, user: @user)

    assert_equal BigDecimal(35), pool.reload.quantity
    assert_equal BigDecimal(20), pool.stock_movements.production.last.quantity
  end

  test "production_batch_size es opcional y debe ser mayor a 0 si se informa" do
    assert item(physical: 1, minimum: 1).valid?

    other = Product.create!(name: "Otro Batch #{rand(1_000_000)}", category: @category, price_cents: 500, cost_cents: 200, active: true, position: 2)
    [ 0, -5 ].each do |invalid|
      assert_not StockItem.new(stockable: other, quantity: 0, minimum_quantity: 1, production_batch_size: invalid).valid?, "#{invalid} debería ser inválido"
    end
    assert StockItem.new(stockable: other, quantity: 0, minimum_quantity: 1, production_batch_size: nil).valid?
    assert StockItem.new(stockable: other, quantity: 0, minimum_quantity: 1, production_batch_size: BigDecimal("22")).valid?
  end

  test "costos y recetas no cambian al informar un lote" do
    raw = RawMaterial.create!(name: "RM Batch #{rand(1_000_000)}", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    masa = Preparation.create!(name: "Masa Batch #{rand(1_000_000)}", yield_quantity: 1.1, yield_unit: "kg")
    masa.recipe_components.create!(component: raw, quantity: 1.1, unit: "kg")
    recipe = ProductRecipe.create!(product: @product, yield_quantity: 10)
    recipe.recipe_components.create!(component: masa, quantity: 0.5, unit: "kg")
    snapshot_data = -> { [ Costing::ProductRecipeCalculator.total_cost_cents(recipe), @product.reload.cost_cents, masa.reload.yield_quantity, masa.yield_unit, recipe.recipe_components.reload.pluck(:id, :quantity, :unit) ] }
    before = snapshot_data.call

    item(physical: 0, minimum: 22, batch: 22)

    assert_equal before, snapshot_data.call
  end
end
