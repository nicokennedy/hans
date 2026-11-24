require "test_helper"
require_relative "../../support/retail_catalog_helpers"
require_relative "../../support/box_helpers"

# Validación única de las cajas con contenido personalizable (Retail::BoxComposition).
class Retail::BoxCompositionTest < ActiveSupport::TestCase
  include RetailCatalogHelpers
  include BoxHelpers

  setup do
    @mix = create_mix_box(publish: false)
    @x24 = box_variant(@mix, 24)
    @almendra, @maicena, @cacao = @mix.ordered_flavors
  end

  # Acepta validate({ id => cant }, variant: ...) y validate(id => cant) (Ruby pasa el hash sin
  # llaves como argumentos con nombre).
  def validate(quantities = {}, variant: @x24, allowed_inactive_ids: [], **inline)
    Retail::BoxComposition.validate(variant: variant, quantities: quantities.merge(inline), allowed_inactive_ids: allowed_inactive_ids)
  end

  test "suma exacta: combinada o toda de un mismo sabor" do
    result = validate(@almendra.id => 12, @maicena.id => 6, @cacao.id => 6)
    assert result.ok?, result.errors.inspect
    assert_equal({ "units" => 24, "flavors" => [
      { "id" => @almendra.id, "name" => "Almendra", "quantity" => 12 },
      { "id" => @maicena.id, "name" => "Maicena", "quantity" => 6 },
      { "id" => @cacao.id, "name" => "Cacao", "quantity" => 6 }
    ] }, result.snapshot)

    assert validate(@almendra.id => 24).ok?
    assert validate({ @maicena.id => 8 }, variant: box_variant(@mix, 8)).ok?
  end

  test "rechaza menos, más, vacía y negativos" do
    assert_match "elegiste 23 (faltan 1)", validate(@almendra.id => 23).errors.first
    assert_match "elegiste 25 (sobran 1)", validate(@almendra.id => 13, @maicena.id => 12).errors.first
    assert_match "Elegí los sabores", validate({}).errors.first
    assert_match "Elegí los sabores", validate(@almendra.id => 0).errors.first
    assert_match "números enteros de 0 o más", validate(@almendra.id => -1, @maicena.id => 25).errors.first
  end

  test "solo sabores del producto y habilitados; el equipo puede conservar uno deshabilitado" do
    other = create_mix_box(publish: false)
    assert_match "no corresponde a este producto", validate(@almendra.id => 12, flavor(other, "Cacao").id => 12).errors.first

    @cacao.update!(active: false)
    @mix.reload
    variant = box_variant(@mix, 24)
    assert_match "“Cacao” ya no está disponible", validate({ @almendra.id => 12, @cacao.id => 12 }, variant: variant).errors.first
    assert validate({ @almendra.id => 12, @cacao.id => 12 }, variant: variant, allowed_inactive_ids: [@cacao.id]).ok?
  end

  test "producto sin personalización o variante sin unidades" do
    @mix.update_columns(customizable_content: false)
    assert_match "no permite elegir sabores", validate({ @almendra.id => 24 }, variant: @mix.reload.variants.first).errors.first

    @mix.update_columns(customizable_content: true)
    @x24.update_columns(content_units: nil)
    assert_match "todavía no tiene definida la cantidad", validate({ @almendra.id => 24 }, variant: @mix.reload.variants.find { |v| v.id == @x24.id }).errors.first
  end

  test "claves del carrito: canónicas, ordenadas y reversibles" do
    key = Retail::BoxComposition.key_for(55, { @maicena.id => 12, @almendra.id => 12, @cacao.id => 0 })
    assert_equal "55:#{[@almendra.id, @maicena.id].sort.map { |id| "#{id}x12" }.join('.')}", key
    assert_equal [55, { @almendra.id => 12, @maicena.id => 12 }], Retail::BoxComposition.parse_key(key)
    assert_equal [55, nil], Retail::BoxComposition.parse_key("55")
    assert_equal "55", Retail::BoxComposition.key_for(55, {})
    ["", "abc", "55:", "55:1x", "55:1x2.", "55:-1x2", "55:1x2;DROP", "1" * 19].each do |bad|
      assert_nil Retail::BoxComposition.parse_key(bad), bad.inspect
      assert_not Retail::BoxComposition.valid_key?(bad)
    end
  end

  test "parámetros del formulario: enteros de 0 o más; texto, decimales y negativos son error" do
    assert_equal [{ 3 => 12 }, []], Retail::BoxComposition.quantities_from_params({ "3" => "12", "4" => "0", "5" => "" })
    ["-1", "1.5", "abc", "1000"].each do |bad|
      _, errors = Retail::BoxComposition.quantities_from_params({ "3" => bad })
      assert_equal ["Las cantidades de cada sabor tienen que ser números enteros de 0 o más."], errors, bad
    end
    _, errors = Retail::BoxComposition.quantities_from_params("3=12")
    assert_equal ["La composición de la caja no es válida."], errors
  end

  test "texto y líneas salen del snapshot guardado, no de los sabores actuales" do
    snapshot = validate(@almendra.id => 20, @cacao.id => 4).snapshot
    @almendra.update!(name: "Almendra glaseada")
    assert_equal "Almendra × 20, Cacao × 4", Retail::BoxComposition.text(snapshot)
    assert_equal({ @almendra.id => 20, @cacao.id => 4 }, Retail::BoxComposition.quantities_from_snapshot(snapshot))
    assert_equal [], Retail::BoxComposition.lines(nil)
  end

  test "máximo de 200 unidades por caja" do
    @x24.content_units = 201
    assert_not @x24.valid?
    @x24.content_units = 200
    assert @x24.valid?
    assert_raises(ActiveRecord::StatementInvalid) { @x24.update_columns(content_units: 201) }
  end
end
