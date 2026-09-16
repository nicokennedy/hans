require "test_helper"

class PreparationTest < ActiveSupport::TestCase
  test "valid with yield_quantity greater than zero" do
    preparation = Preparation.new(name: "Masa Sable", yield_quantity: 2.5, yield_unit: "kg")
    assert preparation.valid?
  end

  test "rejects yield_quantity zero or negative" do
    [ 0, -1 ].each do |quantity|
      preparation = Preparation.new(name: "X", yield_quantity: quantity, yield_unit: "kg")
      assert_not preparation.valid?, "#{quantity} should be invalid"
      assert preparation.errors[:yield_quantity].present?
    end
  end

  test "yield_unit only accepts canonical units (kg/l/un), not g/ml/cc/min" do
    %w[kg l un].each do |unit|
      preparation = Preparation.new(name: "X", yield_quantity: 1, yield_unit: unit)
      assert preparation.valid?, "#{unit} should be valid"
    end

    %w[g ml cc min].each do |unit|
      preparation = Preparation.new(name: "X", yield_quantity: 1, yield_unit: unit)
      assert_not preparation.valid?, "#{unit} should be invalid as yield_unit"
      assert preparation.errors[:yield_unit].present?
    end
  end

  test "active defaults to true" do
    preparation = Preparation.create!(name: "X", yield_quantity: 1, yield_unit: "kg")
    assert preparation.active?
  end

  test "can be created and persisted with no components at all" do
    preparation = Preparation.create!(name: "X", yield_quantity: 1, yield_unit: "kg")

    assert_equal 0, preparation.recipe_components.count
    assert_equal 0, preparation.total_cost_cents
    assert_equal 0, preparation.unit_cost_cents
    assert_equal [], preparation.component_costs
  end

  test "requires a name" do
    preparation = Preparation.new(yield_quantity: 1, yield_unit: "kg")
    assert_not preparation.valid?
    assert preparation.errors[:name].present?
  end

  test "destroying a RecipeComponent does not destroy the referenced RawMaterial, and the owner's cost recalculates immediately" do
    raw_material = RawMaterial.create!(name: "X", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    preparation = Preparation.create!(name: "X", yield_quantity: 1, yield_unit: "kg")
    recipe_component = preparation.recipe_components.create!(component: raw_material, quantity: 1, unit: "kg")

    assert_equal 100_000, preparation.total_cost_cents

    recipe_component.destroy!

    assert RawMaterial.exists?(raw_material.id)
    assert_equal 0, preparation.total_cost_cents
  end

  test "a Preparation referenced by another Preparation's RecipeComponent cannot be destroyed" do
    raw_material = RawMaterial.create!(name: "X", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    child = Preparation.create!(name: "Ganache", yield_quantity: 1, yield_unit: "kg")
    child.recipe_components.create!(component: raw_material, quantity: 1, unit: "kg")

    parent = Preparation.create!(name: "Torta Base", yield_quantity: 1, yield_unit: "kg")
    parent.recipe_components.create!(component: child, quantity: 500, unit: "g")

    result = child.destroy
    assert_equal false, result
    assert child.errors[:base].present?
    assert Preparation.exists?(child.id)
  end

  test "a Preparation with only its own components (not referenced elsewhere) can be destroyed, and its own recipe_components go with it" do
    raw_material = RawMaterial.create!(name: "X", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    preparation = Preparation.create!(name: "X", yield_quantity: 1, yield_unit: "kg")
    recipe_component = preparation.recipe_components.create!(component: raw_material, quantity: 1, unit: "kg")

    assert_difference "Preparation.count", -1 do
      preparation.destroy!
    end
    assert_not RecipeComponent.exists?(recipe_component.id)
    assert RawMaterial.exists?(raw_material.id), "the raw material itself must survive"
  end

  test "depends_on? detects direct self-reference and transitive dependencies" do
    raw_material = RawMaterial.create!(name: "X", purchase_price_cents: 100, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    a = Preparation.create!(name: "A", yield_quantity: 1, yield_unit: "kg")
    b = Preparation.create!(name: "B", yield_quantity: 1, yield_unit: "kg")
    c = Preparation.create!(name: "C", yield_quantity: 1, yield_unit: "kg")

    a.recipe_components.create!(component: raw_material, quantity: 1, unit: "kg")
    b.recipe_components.create!(component: a, quantity: 1, unit: "kg")
    c.recipe_components.create!(component: b, quantity: 1, unit: "kg")

    assert a.depends_on?(a) # auto-referencia
    assert b.depends_on?(a) # directo
    assert c.depends_on?(a) # transitivo (dos niveles)
    assert_not a.depends_on?(b)
    assert_not a.depends_on?(c)
  end
end
