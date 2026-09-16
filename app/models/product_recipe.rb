# La receta final de un Product existente. A diferencia de Preparation, su
# rendimiento SIEMPRE está en "un" (no configurable en esta fase — ver
# YIELD_UNIT) porque conceptualmente representa "cuántas unidades del
# producto produce esta receta", no una cantidad física. Puede existir
# como draft (con o sin componentes) mientras Product#cost_source sigue en
# "manual" — solo gobierna Product#cost_cents cuando se activa
# explícitamente (ver Costing::ActivateProductRecipe). Nunca se borra a
# propósito para no perder el trabajo de armarla — Product#cost_source es
# la única fuente de verdad de si está gobernando o no (ver Product).
class ProductRecipe < ApplicationRecord
  YIELD_UNIT = "un".freeze

  belongs_to :product

  has_many :recipe_components, as: :owner, dependent: :destroy, inverse_of: :owner

  validates :product_id, presence: true, uniqueness: true
  validates :yield_quantity, presence: true, numericality: { greater_than: 0 }

  def total_cost_cents
    Costing::ProductRecipeCalculator.total_cost_cents(self)
  end

  def unit_cost_cents
    Costing::ProductRecipeCalculator.unit_cost_cents(self)
  end

  def component_costs
    Costing::ProductRecipeCalculator.component_costs(self)
  end

  # ¿Tiene todo lo que necesita para poder activarse? (al menos un
  # componente, rendimiento válido). No confirma que el grafo sea
  # calculable sin ciclos — eso lo verifica el calculator en el momento de
  # activar (ver Costing::ActivateProductRecipe).
  def calculable?
    yield_quantity.present? && yield_quantity.to_d.positive? && recipe_components.exists?
  end
end
