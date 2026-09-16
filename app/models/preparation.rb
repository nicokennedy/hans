# Subreceta reutilizable (ej. Masa Sable, Ganache) armada a partir de
# RawMaterial y/u otras Preparation, vía RecipeComponent. El costo NO se
# persiste acá — se calcula siempre on-demand desde los componentes
# actuales (ver Costing::PreparationCalculator), a propósito: todavía no
# existe propagación/caching (esa es una fase posterior), así que cachear
# ahora solo generaría un valor que se desactualiza en silencio.
class Preparation < ApplicationRecord
  # Igual que RawMaterial#base_unit: siempre una unidad canónica, para que
  # el rendimiento de cualquier preparación sea comparable/consumible de
  # forma consistente por quien la use como componente.
  YIELD_UNITS = %w[kg l un].freeze

  # Su propia lista de ingredientes — se borra con ella (es lo mismo que ya
  # hace Order con order_items: son datos de la propia preparación, no de
  # terceros).
  has_many :recipe_components, as: :owner, dependent: :destroy, inverse_of: :owner

  # Dónde ESTA preparación es usada como ingrediente de otra. Acá sí
  # restrict_with_error — no se puede destruir (ni existe UI para hacerlo)
  # una preparación de la que otra depende.
  has_many :component_usages,
    as: :component,
    class_name: "RecipeComponent",
    dependent: :restrict_with_error,
    inverse_of: :component

  scope :active, -> { where(active: true) }

  validates :name, presence: true
  validates :yield_quantity, presence: true, numericality: { greater_than: 0 }
  validates :yield_unit, presence: true, inclusion: { in: YIELD_UNITS }

  def total_cost_cents
    Costing::PreparationCalculator.total_cost_cents(self)
  end

  def unit_cost_cents
    Costing::PreparationCalculator.unit_cost_cents(self)
  end

  def component_costs
    Costing::PreparationCalculator.component_costs(self)
  end

  # ¿"self" aparece, directa o transitivamente, entre los componentes de
  # "other"? Es la pregunta que decide si agregar self como componente de
  # other introduciría un ciclo (ver RecipeComponent#component_does_not_introduce_cycle)
  # y también sirve para filtrar candidatos inválidos en el selector del
  # admin — una sola implementación para las dos necesidades.
  def depends_on?(other, visited = Set.new)
    return false if id.nil? || other.nil? || other.id.nil?
    return true if id == other.id
    return false if visited.include?(id)

    visited << id

    recipe_components.where(component_type: "Preparation").any? do |recipe_component|
      child = recipe_component.component
      child.present? && child.depends_on?(other, visited)
    end
  end
end
