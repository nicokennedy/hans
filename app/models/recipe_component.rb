# Una línea de receta: "tanta cantidad, en tal unidad, de tal componente"
# dentro de una Preparation (y, en una fase posterior, de una ProductRecipe
# también). component es polimórfico a propósito — una misma línea puede
# apuntar a una RawMaterial o a otra Preparation, y desde la perspectiva del
# motor de costeo (Costing::PreparationCalculator) ambas se tratan de forma
# equivalente: cada una expone su propio costo normalizado por unidad base.
class RecipeComponent < ApplicationRecord
  UNITS = %w[kg g l ml cc un].freeze # sin "min" todavía

  # Por ahora solo Preparation puede ser owner — ProductRecipe se sumará acá
  # en una fase posterior, sin tocar el resto de este modelo.
  ALLOWED_OWNER_TYPES = %w[Preparation].freeze
  ALLOWED_COMPONENT_TYPES = %w[RawMaterial Preparation].freeze

  belongs_to :owner, polymorphic: true
  belongs_to :component, polymorphic: true

  validates :quantity, presence: true, numericality: { greater_than: 0 }
  validates :unit, presence: true, inclusion: { in: UNITS }
  validates :owner_type, inclusion: { in: ALLOWED_OWNER_TYPES }
  validates :component_type, inclusion: { in: ALLOWED_COMPONENT_TYPES }
  validate :unit_compatible_with_component
  validate :component_does_not_introduce_cycle

  before_validation :assign_position, on: :create

  def component_label
    component.respond_to?(:name) ? component.name : "componente ##{component_id}"
  end

  private

  def assign_position
    return if position.present? || owner.blank?

    self.position = (owner.recipe_components.maximum(:position) || 0) + 1
  end

  # La unidad de la línea (ej. "g") tiene que ser de la misma dimensión que
  # la unidad de referencia del componente al que apunta: base_unit si es
  # una RawMaterial, yield_unit si es otra Preparation. "200 ml" de una
  # materia prima con base kg no tiene sentido, y viceversa.
  def unit_compatible_with_component
    return if component.blank? || unit.blank?

    target_unit = component_target_unit
    return if target_unit.blank?

    unless Measurement::UnitConverter.compatible?(unit, target_unit)
      errors.add(:unit, "no es compatible con la unidad de #{component_label} (#{target_unit})")
    end
  end

  def component_target_unit
    case component
    when RawMaterial then component.base_unit
    when Preparation then component.yield_unit
    end
  end

  # Único chequeo, cubre tanto la referencia directa (A se agrega a sí
  # misma) como la indirecta (A -> B -> C, C intenta usar A): si el
  # componente ya depende (directa o transitivamente) del owner, agregar
  # esta línea cerraría un ciclo.
  def component_does_not_introduce_cycle
    return unless owner_type == "Preparation" && component_type == "Preparation"
    return if owner.blank? || component.blank?

    if component.depends_on?(owner)
      errors.add(:component, "introduce una dependencia circular entre preparaciones")
    end
  end
end
