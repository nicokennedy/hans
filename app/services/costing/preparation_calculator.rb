require "bigdecimal"

module Costing
  # Calcula el costo de una Preparation recursivamente a partir de sus
  # RecipeComponent actuales — siempre on-demand, nunca persistido (ver
  # comentario en Preparation). Toda la aritmética intermedia se mantiene en
  # BigDecimal; el único redondeo a centavos ocurre en el borde público
  # (total_cost_cents/unit_cost_cents/component_costs), nunca en un paso
  # intermedio — así una preparación anidada dentro de otra no arrastra
  # error de redondeo acumulado.
  #
  # El costo de cada línea individual se delega a ComponentCostCalculator
  # (compartido con ProductRecipeCalculator) — acá solo vive lo que es
  # específico de Preparation: la memoización y la protección anti-ciclos.
  class PreparationCalculator
    class CircularDependencyError < StandardError; end

    def self.total_cost_cents(preparation)
      new.total_cost_cents(preparation)
    end

    def self.unit_cost_cents(preparation)
      new.unit_cost_cents(preparation)
    end

    def self.component_costs(preparation)
      new.component_costs(preparation)
    end

    def initialize
      # Memoización acotada a UNA corrida del calculator: si la misma
      # Preparation aparece más de una vez en el grafo (ej. un "diamante",
      # no un ciclo), se calcula una sola vez. Nunca sobrevive entre calls.
      @memo = {}
    end

    def total_cost_cents(preparation)
      total_cost(preparation, []).round.to_i
    end

    def unit_cost_cents(preparation)
      yield_quantity = preparation.yield_quantity.to_d
      total = total_cost(preparation, [])
      return 0 if yield_quantity.zero?

      (total / yield_quantity).round.to_i
    end

    def component_costs(preparation)
      preparation.recipe_components.includes(:component).order(:position, :id).map do |recipe_component|
        {
          recipe_component: recipe_component,
          cost_cents: ComponentCostCalculator.cost_for(recipe_component, preparation_calculator: self, path: [ preparation.id ]).round.to_i
        }
      end
    end

    # Público a propósito: ComponentCostCalculator lo llama para resolver
    # el costo recursivo de un componente que es otra Preparation, sin
    # duplicar acá la memoización ni la protección anti-ciclos.
    def total_cost(preparation, path)
      return @memo[preparation.id] if preparation.id && @memo.key?(preparation.id)

      guard_against_cycle!(preparation, path)
      next_path = path + [ preparation.id ]

      total = preparation.recipe_components.includes(:component).sum(BigDecimal(0)) do |recipe_component|
        ComponentCostCalculator.cost_for(recipe_component, preparation_calculator: self, path: next_path)
      end

      @memo[preparation.id] = total if preparation.id
      total
    end

    private

    # Última línea de defensa, independiente de la validación del modelo:
    # si por datos corruptos/consola/import llegara a existir un ciclo real
    # en la base, esto lo detecta con un error propio y claro — nunca deja
    # que la recursión llegue a un SystemStackError.
    def guard_against_cycle!(preparation, path)
      return if preparation.id.nil?
      return unless path.include?(preparation.id)

      chain = (path + [ preparation.id ]).join(" -> ")
      raise CircularDependencyError, "Ciclo detectado entre preparaciones (ids: #{chain})"
    end
  end
end
