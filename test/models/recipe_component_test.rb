require "test_helper"

class RecipeComponentTest < ActiveSupport::TestCase
  setup do
    @owner = Preparation.create!(name: "Owner", yield_quantity: 1, yield_unit: "kg")

    @raw_kg = RawMaterial.create!(name: "RawKG", purchase_price_cents: 100, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    @raw_l = RawMaterial.create!(name: "RawL", purchase_price_cents: 100, purchase_quantity: 1, purchase_unit: "l", base_unit: "l")
    @raw_un = RawMaterial.create!(name: "RawUN", purchase_price_cents: 100, purchase_quantity: 1, purchase_unit: "un", base_unit: "un")

    @prep_kg = Preparation.create!(name: "PrepKG", yield_quantity: 1, yield_unit: "kg")
    @prep_l = Preparation.create!(name: "PrepL", yield_quantity: 1, yield_unit: "l")
    @prep_un = Preparation.create!(name: "PrepUN", yield_quantity: 1, yield_unit: "un")
  end

  test "requires a positive quantity" do
    rc = @owner.recipe_components.new(component: @raw_kg, quantity: 0, unit: "kg")
    assert_not rc.valid?
    assert rc.errors[:quantity].present?
  end

  test "requires a valid unit" do
    rc = @owner.recipe_components.new(component: @raw_kg, quantity: 1, unit: "lb")
    assert_not rc.valid?
    assert rc.errors[:unit].present?
  end

  # --- RawMaterial: unidades compatibles ---

  test "kg/g are compatible with a RawMaterial base kg" do
    assert @owner.recipe_components.new(component: @raw_kg, quantity: 200, unit: "g").valid?
    assert @owner.recipe_components.new(component: @raw_kg, quantity: 0.2, unit: "kg").valid?
  end

  test "l/ml/cc are compatible with a RawMaterial base l" do
    assert @owner.recipe_components.new(component: @raw_l, quantity: 150, unit: "ml").valid?
    assert @owner.recipe_components.new(component: @raw_l, quantity: 0.15, unit: "l").valid?
    assert @owner.recipe_components.new(component: @raw_l, quantity: 150, unit: "cc").valid?
  end

  test "un is compatible with a RawMaterial base un" do
    assert @owner.recipe_components.new(component: @raw_un, quantity: 3, unit: "un").valid?
  end

  test "rejects incompatible unit/RawMaterial combinations" do
    harina_ml = @owner.recipe_components.new(component: @raw_kg, quantity: 200, unit: "ml")
    assert_not harina_ml.valid?
    assert harina_ml.errors[:unit].present?

    ganache_un = @owner.recipe_components.new(component: @raw_l, quantity: 2, unit: "un")
    assert_not ganache_un.valid?

    huevos_g = @owner.recipe_components.new(component: @raw_un, quantity: 100, unit: "g")
    assert_not huevos_g.valid?
  end

  # --- Preparation: mismos casos, contra yield_unit ---

  test "kg/g are compatible with a Preparation yield kg" do
    assert @owner.recipe_components.new(component: @prep_kg, quantity: 250, unit: "g").valid?
    assert @owner.recipe_components.new(component: @prep_kg, quantity: 0.25, unit: "kg").valid?
  end

  test "l/ml/cc are compatible with a Preparation yield l" do
    assert @owner.recipe_components.new(component: @prep_l, quantity: 100, unit: "ml").valid?
    assert @owner.recipe_components.new(component: @prep_l, quantity: 0.1, unit: "l").valid?
  end

  test "un is compatible with a Preparation yield un" do
    assert @owner.recipe_components.new(component: @prep_un, quantity: 2, unit: "un").valid?
  end

  test "rejects incompatible unit/Preparation combinations" do
    assert_not @owner.recipe_components.new(component: @prep_kg, quantity: 100, unit: "ml").valid?
    assert_not @owner.recipe_components.new(component: @prep_l, quantity: 2, unit: "un").valid?
    assert_not @owner.recipe_components.new(component: @prep_un, quantity: 100, unit: "g").valid?
  end

  # --- position ---

  test "assigns position automatically in creation order when not given" do
    first = @owner.recipe_components.create!(component: @raw_kg, quantity: 1, unit: "kg")
    second = @owner.recipe_components.create!(component: @raw_l, quantity: 1, unit: "l")

    assert_equal 1, first.position
    assert_equal 2, second.position
  end

  # --- owner_type / component_type ---

  test "only Preparation is an allowed owner_type for now" do
    fake_owner = Customer.create!(name: "FakeOwnerType", active: true)
    rc = RecipeComponent.new(owner_type: "Customer", owner_id: fake_owner.id, component: @raw_kg, quantity: 1, unit: "kg")
    assert_not rc.valid?
    assert rc.errors[:owner_type].present?
  end

  test "only RawMaterial or Preparation are allowed component types" do
    fake_component = Customer.create!(name: "FakeComponentType", active: true)
    rc = RecipeComponent.new(owner: @owner, component_type: "Customer", component_id: fake_component.id, quantity: 1, unit: "kg")
    assert_not rc.valid?
    assert rc.errors[:component_type].present?
  end

  # --- ciclos ---

  test "rejects a preparation adding itself as its own component (direct cycle)" do
    prep = Preparation.create!(name: "SelfCycle", yield_quantity: 1, yield_unit: "kg")

    rc = prep.recipe_components.new(component: prep, quantity: 1, unit: "kg")

    assert_not rc.valid?
    assert_match(/circular/, rc.errors[:component].join)
  end

  test "rejects an indirect cycle: A uses B, B tries to use A" do
    a = Preparation.create!(name: "IndirectA", yield_quantity: 1, yield_unit: "kg")
    b = Preparation.create!(name: "IndirectB", yield_quantity: 1, yield_unit: "kg")
    a.recipe_components.create!(component: b, quantity: 1, unit: "kg")

    rc = b.recipe_components.new(component: a, quantity: 1, unit: "kg")

    assert_not rc.valid?
    assert_match(/circular/, rc.errors[:component].join)
  end

  test "rejects a deep cycle: A -> B -> C, C tries to use A" do
    a = Preparation.create!(name: "DeepA", yield_quantity: 1, yield_unit: "kg")
    b = Preparation.create!(name: "DeepB", yield_quantity: 1, yield_unit: "kg")
    c = Preparation.create!(name: "DeepC", yield_quantity: 1, yield_unit: "kg")
    a.recipe_components.create!(component: b, quantity: 1, unit: "kg")
    b.recipe_components.create!(component: c, quantity: 1, unit: "kg")

    rc = c.recipe_components.new(component: a, quantity: 1, unit: "kg")

    assert_not rc.valid?
    assert_match(/circular/, rc.errors[:component].join)
  end

  test "updating an existing RecipeComponent to introduce a cycle is rejected" do
    a = Preparation.create!(name: "UpdateCycleA", yield_quantity: 1, yield_unit: "kg")
    b = Preparation.create!(name: "UpdateCycleB", yield_quantity: 1, yield_unit: "kg")
    raw = RawMaterial.create!(name: "UpdateCycleRaw", purchase_price_cents: 100, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")

    a.recipe_components.create!(component: b, quantity: 1, unit: "kg")
    editable = b.recipe_components.create!(component: raw, quantity: 1, unit: "kg") # válido: sin ciclo todavía

    editable.component = a # B pasaría a usar A, pero A ya usa B -> ciclo

    assert_not editable.valid?
    assert_match(/circular/, editable.errors[:component].join)
  end

  test "does NOT reject valid non-circular nested preparations (sanity check against false positives)" do
    raw = RawMaterial.create!(name: "SanityRaw", purchase_price_cents: 100, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg")
    a = Preparation.create!(name: "SanityA", yield_quantity: 1, yield_unit: "kg")
    b = Preparation.create!(name: "SanityB", yield_quantity: 1, yield_unit: "kg")
    a.recipe_components.create!(component: raw, quantity: 1, unit: "kg")

    rc = b.recipe_components.new(component: a, quantity: 1, unit: "kg")

    assert rc.valid?
  end
end
