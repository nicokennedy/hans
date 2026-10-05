require "test_helper"

# Pools físicos de tapas de alfajor (cocina cuenta tapas ya porcionadas, no
# alfajores armados). Cada pool es una Preparation "solo stock" en unidades,
# vinculada a sus productos con ProductStockSource. Las masas en kg y las
# recetas NO se tocan: el costeo sigue leyéndolas tal cual.
class Stock::AlfajorPoolsTest < ActiveSupport::TestCase
  def setup
    @category = Category.create!(name: "AlfPools#{rand(1_000_000)}", position: 1, active: true)
    @customer = Customer.create!(name: "Cliente AlfPools #{rand(1_000_000)}", active: true)
    @harina = RawMaterial.create!(name: "Harina AlfPools #{rand(1_000_000)}", purchase_price_cents: 120_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")

    # Masas en kg (las de siempre) -----------------------------------------
    @masa_almendras = masa("Masa almendras", 0.6)
    @masa_sable = masa("Masa Sable", 1.1)
    @masa_cacao = masa("Masa cacao", 1.1)
    @alfa_brownie = masa("Alfa brownie", 1.5)

    # Productos con su receta de siempre (masa en kg) -----------------------
    @almendras = alfajor("Alfajor Almendras", @masa_almendras)
    @ch_blanco = alfajor("Alfajor Almendras CH Blanco", @masa_almendras)
    @sable = alfajor("Alfajor Sable", @masa_sable)
    @pistacho_cfr = alfajor("Alfajor Pistacho C/ FR", @masa_sable)
    @pistacho_sfr = alfajor("Alfajor Pistacho S/FR", @masa_sable)
    @pistacho_alto = alfajor("Alfajor Pistacho alto", @masa_sable) # la receta dice Masa Sable, pero cocina dice otra tapa
    @limon = alfajor("Alfajor Limón", @masa_sable, yield_quantity: 12)
    @cacao_nuez = alfajor("Alfajor Cacao y Nuez", @masa_cacao, kg: 0.55)
    @cafe = alfajor("Alfajor Café", @masa_cacao, kg: 0.55)
    @cacao = alfajor("Alfajor Cacao", @masa_cacao, kg: 0.55)
    @brownie = alfajor("Alfajor brownie", @alfa_brownie, kg: 1.0, yield_quantity: 1)

    @products = [ @almendras, @ch_blanco, @sable, @pistacho_cfr, @pistacho_sfr, @pistacho_alto, @limon, @cacao_nuez, @cafe, @cacao, @brownie ]
    @masas = [ @masa_almendras, @masa_sable, @masa_cacao, @alfa_brownie ]
  end

  def masa(name, yield_kg)
    prep = Preparation.create!(name: "#{name} #{rand(1_000_000)}", yield_quantity: yield_kg, yield_unit: "kg")
    prep.recipe_components.create!(component: @harina, quantity: yield_kg, unit: "kg")
    prep
  end

  def alfajor(name, masa_prep, kg: 0.5, yield_quantity: 10)
    product = Product.create!(name: "#{name} #{rand(1_000_000)}", category: @category, price_cents: 300_000, cost_cents: 100_000, active: true, position: 1)
    recipe = ProductRecipe.create!(product: product, yield_quantity: yield_quantity)
    recipe.recipe_components.create!(component: masa_prep, quantity: kg, unit: "kg")
    product
  end

  # Crea el objeto de stock, lo vincula a sus productos (1 un por alfajor) y lo activa.
  def pool(name, products, minimum:)
    prep = Preparation.create!(name: "#{name} #{rand(1_000_000)}", yield_quantity: 1, yield_unit: "un", stock_only: true)
    products.each { |product| ProductStockSource.create!(product: product, preparation: prep) }
    StockItem.create!(stockable: prep, active: true, quantity: 100, minimum_quantity: minimum)
  end

  def configure_pools
    @almendra_pool = pool("Tapas Alfajor Almendra", [ @almendras, @ch_blanco ], minimum: 88)
    @sable_pool = pool("Tapas Alfajor Sable/Pistacho", [ @sable, @pistacho_cfr, @pistacho_sfr ], minimum: 69)
    @alto_pool = pool("Tapas Alfajor Pistacho Alto", [ @pistacho_alto ], minimum: 20)
    @limon_pool = pool("Tapas Alfajor Limón", [ @limon ], minimum: 15)
    @cacao_pool = pool("Tapas Alfajor Cacao", [ @cacao_nuez, @cafe, @cacao ], minimum: 35)
    @brownie_pool = pool("Base Alfajor Brownie", [ @brownie ], minimum: 23)
  end

  def commit(orders)
    order = Order.new(customer: @customer, delivery_date: Date.current + 7, created_by_admin: true, payment_method_selected: "cash_on_delivery")
    orders.each { |product, quantity| order.order_items.build(product: product, quantity: quantity) }
    order.save!
    order
  end

  def committed(stock_item)
    Stock::Availability.for_item(stock_item).future_committed
  end

  # ---------------------------------------------------------------------------

  test "10 Almendras + 5 Almendras CH Blanco commit 15 Tapas Almendra" do
    configure_pools
    commit(@almendras => 10, @ch_blanco => 5)

    assert_equal BigDecimal(15), committed(@almendra_pool)
  end

  test "10 Pistacho C/FR + 5 Pistacho S/FR + 3 Sable commit 18 Tapas Sable/Pistacho" do
    configure_pools
    commit(@pistacho_cfr => 10, @pistacho_sfr => 5, @sable => 3)

    assert_equal BigDecimal(18), committed(@sable_pool)
  end

  test "Pistacho alto does NOT consume Sable/Pistacho (it has its own pool)" do
    configure_pools
    commit(@pistacho_alto => 7)

    assert_equal BigDecimal(0), committed(@sable_pool)
    assert_equal BigDecimal(7), committed(@alto_pool)
  end

  test "Limón does NOT consume Sable/Pistacho even though its recipe uses Masa Sable (it has its own pool)" do
    configure_pools
    commit(@limon => 4)

    assert_equal BigDecimal(0), committed(@sable_pool)
    assert_equal BigDecimal(4), committed(@limon_pool)
  end

  test "Cacao y Nuez, Café and Alfajor Cacao #14 all consume the same Tapas Cacao" do
    configure_pools
    commit(@cacao_nuez => 4, @cafe => 3, @cacao => 2)

    assert_equal BigDecimal(9), committed(@cacao_pool)
  end

  test "Alfajor brownie does NOT consume Tapas Cacao (it has its own cooked base)" do
    configure_pools
    commit(@brownie => 6)

    assert_equal BigDecimal(0), committed(@cacao_pool)
    assert_equal BigDecimal(6), committed(@brownie_pool)
  end

  test "each sale resolves to exactly the pool and nothing else (no double deduction through the recipe)" do
    configure_pools

    demand = Stock::Demand.for_order_items([ OrderItem.new(product: @almendras, quantity: 10) ])

    assert_equal [ @almendra_pool ], demand.keys
    assert_equal BigDecimal(10), demand[@almendra_pool]
  end

  test "a physical dispatch discounts the pool once, and reconciling again does not discount twice" do
    configure_pools
    order = nil
    travel_to(Time.zone.local(2026, 10, 6, 9, 0, 0)) do
      order = Order.new(customer: @customer, delivery_date: Date.new(2026, 10, 6), created_by_admin: true, payment_method_selected: "cash_on_delivery")
      order.order_items.build(product: @almendras, quantity: 10)
      order.order_items.build(product: @ch_blanco, quantity: 5)
      order.save!
    end

    travel_to Time.zone.local(2026, 10, 6, 14, 0, 0) do
      Stock::DispatchReconciler.call(order)
      Stock::DispatchReconciler.call(order)
      Stock::DispatchReconciler.reconcile_due!

      snapshot = Stock::Availability.for_item(@almendra_pool)
      assert_equal BigDecimal(85), @almendra_pool.reload.quantity # 100 - 15, una sola vez
      assert_equal BigDecimal(85), snapshot.available_quantity # y no se resta de nuevo en "disponible"
    end
    assert_equal 1, StockMovement.dispatch.where(order: order, stock_item: @almendra_pool).count
  end

  test "a canceled order stops committing the pool" do
    configure_pools
    order = commit(@almendras => 10)
    assert_equal BigDecimal(10), committed(@almendra_pool)

    order.update!(status: "canceled")

    assert_equal BigDecimal(0), committed(@almendra_pool)
  end

  test "an inactive pool consumes nothing and does not break the product" do
    configure_pools
    @almendra_pool.update!(active: false)

    assert_equal({}, Stock::ProductConsumption.call(@almendras))
  end

  test "a product with its own active StockItem keeps resolving to itself (the pool link is ignored)" do
    configure_pools
    own = StockItem.create!(stockable: @almendras, active: true, quantity: 5, minimum_quantity: 1)

    assert_equal({ own => BigDecimal(1) }, Stock::ProductConsumption.call(@almendras).to_h)
  end

  test "the link quantity is what one sale consumes (not always 1)" do
    configure_pools
    ProductStockSource.find_by!(product: @almendras).update!(quantity: 2)

    assert_equal BigDecimal(2), Stock::ProductConsumption.call(@almendras)[@almendra_pool]
  end

  # --- Costeo y recetas intactos ---------------------------------------------

  test "product costs are identical before and after configuring the stock pools" do
    cost_snapshot = lambda do
      @products.map do |product|
        product.reload
        [ product.id, product.cost_cents, Costing::ProductRecipeCalculator.total_cost_cents(product.product_recipe), Costing::ProductRecipeCalculator.unit_cost_cents(product.product_recipe) ]
      end
    end

    before = cost_snapshot.call
    assert before.all? { |row| row[2].positive? }, "el escenario tiene que tener costos reales para que la comparación valga"

    configure_pools

    assert_equal before, cost_snapshot.call
  end

  test "the original kg preparations keep their unit, yield, cost and recipes untouched" do
    snapshot = lambda do
      @masas.map do |prep|
        prep.reload
        [ prep.id, prep.yield_unit, prep.yield_quantity, prep.stock_only, prep.total_cost_cents, prep.recipe_components.pluck(:id, :quantity, :unit) ]
      end
    end
    recipes_before = @products.map { |p| [ p.id, p.product_recipe.recipe_components.pluck(:id, :component_id, :quantity, :unit) ] }
    before = snapshot.call

    configure_pools

    assert_equal before, snapshot.call
    assert_equal recipes_before, @products.map { |p| [ p.id, p.product_recipe.recipe_components.reload.pluck(:id, :component_id, :quantity, :unit) ] }
    assert @masas.all? { |prep| prep.reload.yield_unit == "kg" && !prep.stock_only? }
  end

  test "the stock objects can never be added to a recipe, so they can never double the cost" do
    configure_pools

    component = @almendras.product_recipe.recipe_components.build(component: @almendra_pool.stockable, quantity: 10, unit: "un")

    assert_not component.valid?
  end
end
