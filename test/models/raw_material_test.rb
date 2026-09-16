require "test_helper"

class RawMaterialTest < ActiveSupport::TestCase
  test "computes unit_cost_cents correctly when purchase_unit == base_unit" do
    raw_material = RawMaterial.create!(
      name: "Harina 0000", purchase_price_cents: 2_500_000, purchase_quantity: 25,
      purchase_unit: "kg", base_unit: "kg"
    )

    assert_equal 100_000, raw_material.unit_cost_cents # $1.000/kg
  end

  test "computes unit_cost_cents correctly for 500 g purchased with base kg" do
    raw_material = RawMaterial.create!(
      name: "Chocolate blanco", purchase_price_cents: 200_000, purchase_quantity: 500,
      purchase_unit: "g", base_unit: "kg"
    )

    assert_equal 400_000, raw_material.unit_cost_cents # $4.000/kg
  end

  test "computes unit_cost_cents correctly for 500 ml purchased with base l" do
    raw_material = RawMaterial.create!(
      name: "Crema", purchase_price_cents: 300_000, purchase_quantity: 500,
      purchase_unit: "ml", base_unit: "l"
    )

    assert_equal 600_000, raw_material.unit_cost_cents # $6.000/l
  end

  test "requires purchase_quantity greater than zero" do
    raw_material = RawMaterial.new(name: "X", purchase_price_cents: 100, purchase_quantity: 0, purchase_unit: "kg", base_unit: "kg")

    assert_not raw_material.valid?
    assert raw_material.errors[:purchase_quantity].present?
  end

  test "rejects a negative purchase_quantity" do
    raw_material = RawMaterial.new(name: "X", purchase_price_cents: 100, purchase_quantity: -5, purchase_unit: "kg", base_unit: "kg")

    assert_not raw_material.valid?
    assert raw_material.errors[:purchase_quantity].present?
  end

  test "requires purchase_price_cents to be present and non-negative" do
    without_price = RawMaterial.new(name: "X", purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    assert_not without_price.valid?
    assert without_price.errors[:purchase_price_cents].present?

    negative_price = RawMaterial.new(name: "X", purchase_price_cents: -1, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    assert_not negative_price.valid?
    assert negative_price.errors[:purchase_price_cents].present?
  end

  test "purchase_price_cents of zero is allowed (a free/donated input is a valid business case)" do
    raw_material = RawMaterial.new(name: "X", purchase_price_cents: 0, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")

    assert raw_material.valid?
    assert_equal 0, raw_material.unit_cost_cents
  end

  test "only accepts valid purchase units" do
    raw_material = RawMaterial.new(name: "X", purchase_price_cents: 100, purchase_quantity: 1, purchase_unit: "lb", base_unit: "kg")

    assert_not raw_material.valid?
    assert raw_material.errors[:purchase_unit].present?
  end

  test "base_unit is restricted to canonical units (kg, l, un) — g/ml/cc are rejected as a base_unit" do
    %w[g ml cc].each do |non_canonical|
      raw_material = RawMaterial.new(name: "X", purchase_price_cents: 100, purchase_quantity: 1, purchase_unit: "kg", base_unit: non_canonical)
      assert_not raw_material.valid?, "#{non_canonical} should not be a valid base_unit"
      assert raw_material.errors[:base_unit].present?
    end
  end

  test "rejects incompatible purchase_unit/base_unit combinations (kg vs l)" do
    raw_material = RawMaterial.new(name: "X", purchase_price_cents: 100, purchase_quantity: 1, purchase_unit: "kg", base_unit: "l")

    assert_not raw_material.valid?
    assert_match(/no es compatible/, raw_material.errors[:base_unit].join)
  end

  test "rejects incompatible purchase_unit/base_unit combinations (un vs kg)" do
    raw_material = RawMaterial.new(name: "X", purchase_price_cents: 100, purchase_quantity: 1, purchase_unit: "un", base_unit: "kg")

    assert_not raw_material.valid?
    assert raw_material.errors[:base_unit].present?
  end

  test "unit_cost_cents can never be set manually — it's always recalculated, ignoring whatever was assigned" do
    raw_material = RawMaterial.new(
      name: "X", purchase_price_cents: 2_500_000, purchase_quantity: 25,
      purchase_unit: "kg", base_unit: "kg", unit_cost_cents: 999_999_999
    )

    raw_material.valid?

    assert_equal 100_000, raw_material.unit_cost_cents
    assert_not_equal 999_999_999, raw_material.unit_cost_cents
  end

  test "active defaults to true" do
    raw_material = RawMaterial.create!(name: "X", purchase_price_cents: 100, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")

    assert raw_material.active?
  end

  test "a raw material WITH cost history cannot be destroyed — the history stays protected, never silently deleted" do
    admin = User.create!(email: "rm-destroy-admin@example.com", password: "password123", role: "admin")
    raw_material = RawMaterial.create!(name: "X", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    RawMaterials::UpdateWithCostHistory.call(raw_material: raw_material, attributes: { purchase_price_amount: "1200" }, changed_by: admin)
    assert_equal 1, raw_material.cost_changes.count

    result = raw_material.destroy
    assert_equal false, result
    assert raw_material.errors[:base].present?

    assert RawMaterial.exists?(raw_material.id), "the raw material itself must survive the blocked destroy"
    assert_equal 1, RawMaterialCostChange.where(raw_material_id: raw_material.id).count, "history must remain intact"
  end

  test "a raw material with NO cost history can still be destroyed (nothing to protect)" do
    raw_material = RawMaterial.create!(name: "X", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    assert_equal 0, raw_material.cost_changes.count

    assert_difference "RawMaterial.count", -1 do
      raw_material.destroy!
    end
  end

  test "purchase_format renders quantity and unit without trailing zeros" do
    raw_material = RawMaterial.create!(name: "X", purchase_price_cents: 100, purchase_quantity: 25, purchase_unit: "kg", base_unit: "kg")
    assert_equal "25 kg", raw_material.purchase_format

    raw_material.update!(purchase_quantity: 0.5, purchase_unit: "l", base_unit: "l")
    assert_equal "0.5 l", raw_material.purchase_format
  end
end
