require "test_helper"

class RawMaterials::UpdateWithCostHistoryTest < ActiveSupport::TestCase
  setup do
    @admin = User.create!(email: "rm-history-admin@example.com", password: "password123", role: "admin")
    # $1.000 por 1 kg -> unit_cost_cents = 100_000 ($1.000/kg)
    @raw_material = RawMaterial.create!(
      name: "Manteca", category: "Lácteos", brand: "La Paulina", supplier: "Reposmar",
      purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg"
    )
  end

  test "creating a RawMaterial does not create any cost history (no 'change from nothing')" do
    assert_equal 0, @raw_material.cost_changes.count
  end

  test "changing the purchase price creates a cost history record" do
    assert_difference "@raw_material.cost_changes.count", 1 do
      RawMaterials::UpdateWithCostHistory.call(
        raw_material: @raw_material,
        attributes: { purchase_price_amount: "1200" },
        changed_by: @admin
      )
    end

    change = @raw_material.cost_changes.order(:created_at).last
    assert_equal 100_000, change.previous_purchase_price_cents
    assert_equal 120_000, change.new_purchase_price_cents
    assert_equal 100_000, change.previous_unit_cost_cents
    assert_equal 120_000, change.new_unit_cost_cents
    assert_equal @admin, change.changed_by_user
  end

  test "Manteca scenario: 1kg/$10.000 -> 500g/$6.000 (base kg) reconstructs the full reason for the cost change" do
    manteca = RawMaterial.create!(
      name: "Manteca Escenario", purchase_price_cents: 1_000_000, purchase_quantity: 1,
      purchase_unit: "kg", base_unit: "kg"
    )
    assert_equal 1_000_000, manteca.unit_cost_cents # $10.000/kg

    assert_difference "manteca.cost_changes.count", 1 do
      RawMaterials::UpdateWithCostHistory.call(
        raw_material: manteca,
        attributes: { purchase_price_amount: "6000", purchase_quantity: 500, purchase_unit: "g" },
        changed_by: @admin
      )
    end

    manteca.reload
    assert_equal 600_000, manteca.purchase_price_cents # $6.000
    assert_equal 500, manteca.purchase_quantity.to_i
    assert_equal "g", manteca.purchase_unit
    assert_equal "kg", manteca.base_unit
    assert_equal 1_200_000, manteca.unit_cost_cents # $12.000/kg

    change = manteca.cost_changes.order(:created_at).last
    assert_equal 1_000_000, change.previous_purchase_price_cents # $10.000
    assert_equal 600_000, change.new_purchase_price_cents # $6.000
    assert_equal 1, change.previous_purchase_quantity.to_i
    assert_equal "kg", change.previous_purchase_unit
    assert_equal 500, change.new_purchase_quantity.to_i
    assert_equal "g", change.new_purchase_unit
    assert_equal "kg", change.previous_base_unit
    assert_equal "kg", change.new_base_unit
    assert_equal 1_000_000, change.previous_unit_cost_cents # $10.000/kg
    assert_equal 1_200_000, change.new_unit_cost_cents # $12.000/kg
  end

  test "changing purchase_quantity and purchase_unit together, altering unit_cost, is recorded with full before/after detail" do
    # Antes: 1 kg a $1.000 ($1.000/kg). Después: 500 g a $600 ($1.200/kg).
    # El precio "bajó" en términos absolutos pero el costo por kg subió —
    # por eso el historial mira el costo efectivo, no solo el precio.
    RawMaterials::UpdateWithCostHistory.call(
      raw_material: @raw_material,
      attributes: { purchase_price_amount: "600", purchase_quantity: 500, purchase_unit: "g" },
      changed_by: @admin
    )

    change = @raw_material.cost_changes.order(:created_at).last
    assert_equal 1, change.previous_purchase_quantity.to_i
    assert_equal "kg", change.previous_purchase_unit
    assert_equal 500, change.new_purchase_quantity.to_i
    assert_equal "g", change.new_purchase_unit
    assert_equal 100_000, change.previous_unit_cost_cents # $1.000/kg
    assert_equal 120_000, change.new_unit_cost_cents # $600 / 0.5kg = $1.200/kg
  end

  test "an update that does not change the effective unit_cost_cents does NOT create history" do
    assert_no_difference "@raw_material.cost_changes.count" do
      RawMaterials::UpdateWithCostHistory.call(
        raw_material: @raw_material,
        attributes: { category: "Lácteos frescos", brand: "La Paulina" },
        changed_by: @admin
      )
    end

    @raw_material.reload
    assert_equal "Lácteos frescos", @raw_material.category
  end

  test "an update that re-sets the exact same price/quantity/units does NOT create history" do
    assert_no_difference "@raw_material.cost_changes.count" do
      RawMaterials::UpdateWithCostHistory.call(
        raw_material: @raw_material,
        attributes: { purchase_price_amount: "1000" }, # mismo valor que ya tenía
        changed_by: @admin
      )
    end
  end

  test "update + history creation are atomic: an invalid update rolls back everything and creates no history" do
    original_price = @raw_material.purchase_price_cents

    assert_raises(ActiveRecord::RecordInvalid) do
      RawMaterials::UpdateWithCostHistory.call(
        raw_material: @raw_material,
        attributes: { purchase_quantity: 0 }, # inválido: debe ser > 0
        changed_by: @admin
      )
    end

    assert_equal original_price, @raw_material.reload.purchase_price_cents
    assert_equal 0, @raw_material.cost_changes.count
  end

  test "atomicity, forced: if RawMaterialCostChange creation itself fails, the RawMaterial update is fully rolled back" do
    original_price_cents = @raw_material.purchase_price_cents
    original_quantity = @raw_material.purchase_quantity
    original_unit_cost_cents = @raw_material.unit_cost_cents

    # No alcanza con un update inválido de RawMaterial (ese caso ya está
    # cubierto arriba) — acá forzamos, de manera controlada, que falle
    # específicamente la creación del RawMaterialCostChange (el segundo paso
    # de la transacción), para probar que ni siquiera eso deja a la
    # RawMaterial parcialmente actualizada.
    RawMaterialCostChange.stub(:create!, ->(*) { raise ActiveRecord::RecordInvalid.new(RawMaterialCostChange.new) }) do
      assert_raises(ActiveRecord::RecordInvalid) do
        RawMaterials::UpdateWithCostHistory.call(
          raw_material: @raw_material,
          attributes: { purchase_price_amount: "1200" }, # válido por sí solo
          changed_by: @admin
        )
      end
    end

    @raw_material.reload
    assert_equal original_price_cents, @raw_material.purchase_price_cents
    assert_equal original_quantity, @raw_material.purchase_quantity
    assert_equal original_unit_cost_cents, @raw_material.unit_cost_cents
    assert_equal 0, @raw_material.cost_changes.count
  end

  test "the history record preserves previous and new values correctly across two consecutive changes" do
    RawMaterials::UpdateWithCostHistory.call(
      raw_material: @raw_material, attributes: { purchase_price_amount: "1100" }, changed_by: @admin
    )
    RawMaterials::UpdateWithCostHistory.call(
      raw_material: @raw_material, attributes: { purchase_price_amount: "1300" }, changed_by: @admin
    )

    changes = @raw_material.cost_changes.order(:created_at)
    assert_equal 2, changes.count

    first, second = changes.first, changes.second
    assert_equal 100_000, first.previous_unit_cost_cents
    assert_equal 110_000, first.new_unit_cost_cents
    assert_equal 110_000, second.previous_unit_cost_cents
    assert_equal 130_000, second.new_unit_cost_cents
  end

  test "RawMaterialCostChange records are read-only once created" do
    RawMaterials::UpdateWithCostHistory.call(
      raw_material: @raw_material, attributes: { purchase_price_amount: "1200" }, changed_by: @admin
    )
    change = @raw_material.cost_changes.last

    assert_raises(ActiveRecord::ReadOnlyRecord) do
      change.update!(note: "intento de edición")
    end
  end
end
