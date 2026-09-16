require "test_helper"

class Costing::PreparationCalculatorTest < ActiveSupport::TestCase
  test "Caso 1: Masa Sable a partir de materias primas" do
    harina = RawMaterial.create!(name: "Harina Calc1", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg") # $1.000/kg
    manteca = RawMaterial.create!(name: "Manteca Calc1", purchase_price_cents: 1_000_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg") # $10.000/kg
    azucar = RawMaterial.create!(name: "Azucar Calc1", purchase_price_cents: 200_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg") # $2.000/kg

    masa = Preparation.create!(name: "Masa Sable Calc1", yield_quantity: 2, yield_unit: "kg")
    masa.recipe_components.create!(component: harina, quantity: 1000, unit: "g")
    masa.recipe_components.create!(component: manteca, quantity: 500, unit: "g")
    masa.recipe_components.create!(component: azucar, quantity: 300, unit: "g")

    assert_equal 660_000, masa.total_cost_cents # $6.600
    assert_equal 330_000, masa.unit_cost_cents # $3.300/kg

    costs = masa.component_costs
    assert_equal 100_000, costs.find { |c| c[:recipe_component].component == harina }[:cost_cents]
    assert_equal 500_000, costs.find { |c| c[:recipe_component].component == manteca }[:cost_cents]
    assert_equal 60_000, costs.find { |c| c[:recipe_component].component == azucar }[:cost_cents]
  end

  test "Caso 2: preparación dentro de preparación (Ganache llega a $8.000/kg por sus propios componentes)" do
    chocolate = RawMaterial.create!(name: "Chocolate Calc2", purchase_price_cents: 800_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    ganache = Preparation.create!(name: "Ganache Calc2", yield_quantity: 1, yield_unit: "kg")
    ganache.recipe_components.create!(component: chocolate, quantity: 1, unit: "kg")
    assert_equal 800_000, ganache.unit_cost_cents

    torta = Preparation.create!(name: "Torta Base Calc2", yield_quantity: 1, yield_unit: "kg")
    torta.recipe_components.create!(component: ganache, quantity: 500, unit: "g")

    assert_equal 400_000, torta.total_cost_cents # 0.5 * $8.000
    assert_equal 400_000, torta.component_costs.first[:cost_cents]
  end

  test "Caso 3: actualización on-demand — cambiar el costo de una RawMaterial se refleja sin tocar la Preparation" do
    chocolate = RawMaterial.create!(name: "Chocolate Calc3", purchase_price_cents: 800_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    ganache = Preparation.create!(name: "Ganache Calc3", yield_quantity: 1, yield_unit: "kg")
    ganache.recipe_components.create!(component: chocolate, quantity: 1, unit: "kg")
    assert_equal 800_000, ganache.unit_cost_cents

    chocolate.update!(purchase_price_amount: "12000") # $8.000/kg -> $12.000/kg

    assert_equal 1_200_000, ganache.unit_cost_cents
  end

  test "Caso 4: anidación múltiple — A usa RawMaterial, B usa A, C usa B" do
    raw = RawMaterial.create!(name: "Raw Calc4", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    a = Preparation.create!(name: "A Calc4", yield_quantity: 1, yield_unit: "kg")
    a.recipe_components.create!(component: raw, quantity: 1, unit: "kg")
    b = Preparation.create!(name: "B Calc4", yield_quantity: 1, yield_unit: "kg")
    b.recipe_components.create!(component: a, quantity: 1, unit: "kg")
    c = Preparation.create!(name: "C Calc4", yield_quantity: 1, yield_unit: "kg")
    c.recipe_components.create!(component: b, quantity: 1, unit: "kg")

    assert_equal 100_000, a.unit_cost_cents
    assert_equal 100_000, b.unit_cost_cents
    assert_equal 100_000, c.unit_cost_cents
  end

  test "an empty preparation costs 0, not nil" do
    empty = Preparation.create!(name: "Vacia Calc", yield_quantity: 1, yield_unit: "kg")

    assert_equal 0, empty.total_cost_cents
    assert_equal 0, empty.unit_cost_cents
    assert_equal [], empty.component_costs
  end

  test "diamond dependency (not a cycle) computes correctly — memoization does not corrupt the result" do
    raw = RawMaterial.create!(name: "DiamondRaw", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    d = Preparation.create!(name: "DiamondD", yield_quantity: 1, yield_unit: "kg")
    d.recipe_components.create!(component: raw, quantity: 1, unit: "kg")

    a = Preparation.create!(name: "DiamondA", yield_quantity: 1, yield_unit: "kg")
    a.recipe_components.create!(component: d, quantity: 1, unit: "kg")
    b = Preparation.create!(name: "DiamondB", yield_quantity: 1, yield_unit: "kg")
    b.recipe_components.create!(component: d, quantity: 1, unit: "kg")

    top = Preparation.create!(name: "DiamondTop", yield_quantity: 2, yield_unit: "kg")
    top.recipe_components.create!(component: a, quantity: 1, unit: "kg")
    top.recipe_components.create!(component: b, quantity: 1, unit: "kg")

    assert_equal 200_000, top.total_cost_cents # D vale 100_000, y se usa dos veces (vía A y vía B), sin ser un ciclo
  end

  test "cycle detection: the calculator raises a controlled error (never SystemStackError) even with corrupted data that bypassed validations" do
    a = Preparation.create!(name: "CycleCalcA", yield_quantity: 1, yield_unit: "kg")
    b = Preparation.create!(name: "CycleCalcB", yield_quantity: 1, yield_unit: "kg")
    a.recipe_components.create!(component: b, quantity: 1, unit: "kg")

    # Salteamos la validación del modelo a propósito, para simular datos
    # corruptos (consola/import manual) y probar la protección defensiva
    # del calculator en sí, no la del modelo.
    corrupt = b.recipe_components.build(component: a, quantity: 1, unit: "kg")
    corrupt.save!(validate: false)

    error = assert_raises(Costing::PreparationCalculator::CircularDependencyError) do
      a.total_cost_cents
    end
    assert_match(/Ciclo detectado/, error.message)
  end
end
