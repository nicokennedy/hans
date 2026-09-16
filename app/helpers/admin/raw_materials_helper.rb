module Admin::RawMaterialsHelper
  UNIT_LABELS = {
    "kg" => "Kilogramos (kg)",
    "g" => "Gramos (g)",
    "l" => "Litros (l)",
    "ml" => "Mililitros (ml)",
    "cc" => "Centímetros cúbicos (cc)",
    "un" => "Unidades (un)"
  }.freeze

  UNIT_OPTIONS = RawMaterial::PURCHASE_UNITS.map { |unit| [ UNIT_LABELS.fetch(unit), unit ] }.freeze
  BASE_UNIT_OPTIONS = RawMaterial::CANONICAL_BASE_UNITS.map { |unit| [ UNIT_LABELS.fetch(unit), unit ] }.freeze
end
