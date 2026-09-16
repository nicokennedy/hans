require "bigdecimal"

module Costing
  # Calcula el costo de una Preparation recursivamente a partir de sus
  # RecipeComponent actuales — siempre on-demand, nunca persistido (ver
  # comentario en Preparation). Toda la aritmética intermedia se mantiene en
  # BigDecimal; el único redondeo a centavos ocurre en el borde público
  # (total_cost_cents/unit_cost_cents/component_costs), nunca en un paso
  # intermedio — así una preparación anidada dentro de otra no arrastra
  # error de redondeo acumulado.
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
          cost_cents: component_cost(recipe_component, [ preparation.id ]).round.to_i
        }
      end
    end

    private

    def total_cost(preparation, path)
      return @memo[preparation.id] if preparation.id && @memo.key?(preparation.id)

      guard_against_cycle!(preparation, path)
      next_path = path + [ preparation.id ]

      total = preparation.recipe_components.includes(:component).sum(BigDecimal(0)) do |recipe_component|
        component_cost(recipe_component, next_path)
      end

      @memo[preparation.id] = total if preparation.id
      total
    end

    def component_cost(recipe_component, path)
      component = recipe_component.component
      return BigDecimal(0) if component.nil?

      case component
      when RawMaterial
        raw_material_component_cost(recipe_component, component)
      when Preparation
        preparation_component_cost(recipe_component, component, path)
      else
        BigDecimal(0)
      end
    end

    # Fórmula: convertir quantity/unit a base_unit de la materia prima, y
    # multiplicar por su unit_cost_cents (ya está en centavos por
    # base_unit, calculado y persistido en Fase 2 — se usa directo, sin
    # reconvertir nada más).
    def raw_material_component_cost(recipe_component, raw_material)
      quantity_in_base_unit = Measurement::UnitConverter.convert(
        recipe_component.quantity, from: recipe_component.unit, to: raw_material.base_unit
      )

      quantity_in_base_unit * BigDecimal(raw_material.unit_cost_cents.to_s)
    end

    # Fórmula: costo normalizado de la preparación hija (recursivo, en
    # BigDecimal, sin redondear todavía) por la cantidad consumida
    # convertida a su yield_unit.
    def preparation_component_cost(recipe_component, child_preparation, path)
      child_total = total_cost(child_preparation, path)
      child_yield = child_preparation.yield_quantity.to_d
      child_unit_cost = child_yield.zero? ? BigDecimal(0) : child_total / child_yield

      quantity_in_yield_unit = Measurement::UnitConverter.convert(
        recipe_component.quantity, from: recipe_component.unit, to: child_preparation.yield_unit
      )

      quantity_in_yield_unit * child_unit_cost
    end

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
