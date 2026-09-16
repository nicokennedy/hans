module Costing
  # Valida que el grafo de costeo de una ProductRecipe esté completo: que ni
  # la propia ProductRecipe ni ninguna Preparation alcanzable, directa o
  # indirectamente, esté vacía (0 RecipeComponents).
  #
  # Distinto, a propósito, de Costing::PreparationCalculator: ese calculador
  # sigue tolerando una Preparation vacía y la computa en $0 — eso es
  # correcto mientras se la está armando (Fase 3, "fórmula viva", no se
  # toca). Esta clase es la regla específica del contexto en el que una
  # ProductRecipe gobierna el costo de un Product: ahí una Preparation
  # vacía no es un $0 legítimo, es un grafo incompleto. Por eso NUNCA mira
  # el costo (un costo $0 matemáticamente legítimo, ej. una materia prima
  # gratuita, no es un error) — solo mira la forma del grafo.
  #
  # Único punto de esta regla: Costing::ActivateProductRecipe y
  # Costing::SyncProductCost la usan (y por lo tanto también
  # Costing::PropagateCostChange, que siempre pasa por SyncProductCost) en
  # vez de tener cada uno su propio criterio de "completo".
  class RecipeGraphCompleteness
    class IncompleteGraphError < StandardError; end

    def self.check!(product_recipe)
      new.check!(product_recipe)
    end

    def check!(product_recipe)
      if product_recipe.recipe_components.none?
        raise IncompleteGraphError, "La receta no tiene componentes"
      end

      product_recipe.recipe_components.includes(:component).each do |recipe_component|
        check_component!(recipe_component.component, [])
      end
    end

    private

    # path acumula ids de Preparation ya visitadas en esta rama, como
    # protección defensiva contra un ciclo corrupto (nunca debería existir
    # uno que haya pasado por la validación normal) — si se repite, corta
    # en silencio acá; el ciclo en sí ya lo detecta y reporta
    # PreparationCalculator al calcular el costo, que corre después.
    def check_component!(component, path)
      return if component.nil? || !component.is_a?(Preparation)
      return if path.include?(component.id)

      if component.recipe_components.none?
        raise IncompleteGraphError, "\"#{component.name}\" no tiene componentes"
      end

      component.recipe_components.includes(:component).each do |nested|
        check_component!(nested.component, path + [component.id])
      end
    end
  end
end
