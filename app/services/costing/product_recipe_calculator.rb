require "bigdecimal"

module Costing
  # Calcula el costo de una ProductRecipe a partir de sus RecipeComponent
  # actuales — mismo criterio que PreparationCalculator (BigDecimal hasta
  # el borde, redondeo único a centavos), y reutiliza exactamente la misma
  # fórmula por componente vía ComponentCostCalculator. No necesita su
  # propia protección anti-ciclos: una ProductRecipe nunca puede ser
  # component de nada (RecipeComponent::ALLOWED_COMPONENT_TYPES no incluye
  # "ProductRecipe" ni "Product"), así que nunca puede formar parte de un
  # ciclo — solo puede ser la raíz.
  class ProductRecipeCalculator
    def self.total_cost_cents(product_recipe)
      new.total_cost_cents(product_recipe)
    end

    def self.unit_cost_cents(product_recipe)
      new.unit_cost_cents(product_recipe)
    end

    def self.component_costs(product_recipe)
      new.component_costs(product_recipe)
    end

    def initialize
      # Una instancia propia de PreparationCalculator por corrida: si la
      # ProductRecipe usa la misma Preparation en más de un componente (o
      # anidada dos veces), se calcula una sola vez gracias a su memo.
      @preparation_calculator = PreparationCalculator.new
    end

    def total_cost_cents(product_recipe)
      total_cost(product_recipe).round.to_i
    end

    def unit_cost_cents(product_recipe)
      yield_quantity = product_recipe.yield_quantity.to_d
      total = total_cost(product_recipe)
      return 0 if yield_quantity.zero?

      (total / yield_quantity).round.to_i
    end

    def component_costs(product_recipe)
      product_recipe.recipe_components.includes(:component).order(:position, :id).map do |recipe_component|
        {
          recipe_component: recipe_component,
          cost_cents: ComponentCostCalculator.cost_for(recipe_component, preparation_calculator: @preparation_calculator, path: []).round.to_i
        }
      end
    end

    private

    def total_cost(product_recipe)
      product_recipe.recipe_components.includes(:component).sum(BigDecimal(0)) do |recipe_component|
        ComponentCostCalculator.cost_for(recipe_component, preparation_calculator: @preparation_calculator, path: [])
      end
    end
  end
end
