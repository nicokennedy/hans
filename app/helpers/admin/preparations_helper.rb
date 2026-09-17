module Admin::PreparationsHelper
  # Reusa las mismas etiquetas ya definidas para materias primas — un solo
  # lugar con el texto humano de cada unidad, sin duplicarlo acá.
  YIELD_UNIT_OPTIONS = Preparation::YIELD_UNITS.map { |unit| [ Admin::RawMaterialsHelper::UNIT_LABELS.fetch(unit), unit ] }.freeze
  COMPONENT_UNIT_OPTIONS = RecipeComponent::UNITS.map { |unit| [ Admin::RawMaterialsHelper::UNIT_LABELS.fetch(unit), unit ] }.freeze

  # Nunca debería dispararse por un camino normal (la validación de
  # RecipeComponent ya impide guardar un ciclo) — pero si datos corruptos
  # (consola/import manual) lo produjeran, esto evita que una sola fila
  # rota tire abajo el listado completo de preparaciones.
  def preparation_cost_display(preparation)
    [ format_money(preparation.total_cost_cents), "#{format_money(preparation.unit_cost_cents)}/#{preparation.yield_unit}" ]
  rescue Costing::PreparationCalculator::CircularDependencyError
    [ "—", "—" ]
  end

  def component_ref_options(raw_materials, preparations, selected: nil)
    raw_material_options = raw_materials.map { |rm| [ rm.name, "RawMaterial:#{rm.id}" ] }
    preparation_options = preparations.map { |p| [ p.name, "Preparation:#{p.id}" ] }

    grouped_options_for_select(
      [ [ "Materias primas", raw_material_options ], [ "Preparaciones", preparation_options ] ],
      selected
    )
  end
end
