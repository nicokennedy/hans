require "bigdecimal"

module Costing
  # Costo (BigDecimal, sin redondear) que aporta UN RecipeComponent —
  # extraído de PreparationCalculator porque la fórmula es idéntica sea
  # cual sea el owner (Preparation o ProductRecipe): solo depende del
  # componente (RawMaterial o Preparation), nunca de quién lo usa. Sin este
  # punto único, ProductRecipeCalculator hubiera terminado con una copia de
  # este mismo case/when que diverge con el tiempo.
  #
  # Para un componente Preparation, delega el cálculo recursivo al
  # PreparationCalculator que se le pasa — así la memoización y la
  # protección anti-ciclos siguen viviendo en un solo lugar, compartidas
  # entre quien sea que esté armando el costo (una Preparation padre o una
  # ProductRecipe).
  class ComponentCostCalculator
    def self.cost_for(recipe_component, preparation_calculator:, path:)
      new(preparation_calculator).cost_for(recipe_component, path)
    end

    def initialize(preparation_calculator)
      @preparation_calculator = preparation_calculator
    end

    def cost_for(recipe_component, path)
      component = recipe_component.component
      return BigDecimal(0) if component.nil?

      case component
      when RawMaterial
        raw_material_cost(recipe_component, component)
      when Preparation
        preparation_cost(recipe_component, component, path)
      else
        BigDecimal(0)
      end
    end

    private

    attr_reader :preparation_calculator

    # Fórmula: convertir quantity/unit a base_unit de la materia prima, y
    # multiplicar por su unit_cost_cents (ya en centavos por base_unit,
    # calculado y persistido en Fase 2 — se usa directo, sin reconvertir).
    def raw_material_cost(recipe_component, raw_material)
      quantity_in_base_unit = Measurement::UnitConverter.convert(
        recipe_component.quantity, from: recipe_component.unit, to: raw_material.base_unit
      )

      quantity_in_base_unit * BigDecimal(raw_material.unit_cost_cents.to_s)
    end

    # Fórmula: costo normalizado de la preparación hija (recursivo, en
    # BigDecimal, sin redondear todavía) por la cantidad consumida
    # convertida a su yield_unit.
    def preparation_cost(recipe_component, child_preparation, path)
      child_total = preparation_calculator.total_cost(child_preparation, path)
      child_yield = child_preparation.yield_quantity.to_d
      child_unit_cost = child_yield.zero? ? BigDecimal(0) : child_total / child_yield

      quantity_in_yield_unit = Measurement::UnitConverter.convert(
        recipe_component.quantity, from: recipe_component.unit, to: child_preparation.yield_unit
      )

      quantity_in_yield_unit * child_unit_cost
    end
  end
end
