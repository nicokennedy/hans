module Costing
  # Única operación responsable de sincronizar Product#cost_cents con su
  # ProductRecipe actual. No hace nada (silenciosamente, a propósito) si el
  # producto no está en modo recipe o no tiene receta — un producto manual
  # nunca debe verse tocado por esto, sin importar desde dónde se lo llame.
  class SyncProductCost
    # Un producto recipe-sourced cuya receta quedó sin componentes (o sin
    # yield válido) no puede sincronizarse en silencio a costo 0 — eso
    # escondería el problema. Se levanta para que quien dispare esto desde
    # una mutación (ej. borrar el último componente) la vea rechazada y el
    # Product conserve su costo anterior (ver PropagateCostChange, que
    # corre esto dentro de la misma transacción que la mutación).
    class SyncError < StandardError; end

    def self.call(product)
      new(product).call
    end

    def initialize(product)
      @product = product
    end

    def call
      return unless product.recipe?

      product_recipe = product.product_recipe
      return if product_recipe.blank?

      unless product_recipe.calculable?
        raise SyncError, "La receta de \"#{product.name}\" quedó sin componentes o sin rendimiento válido"
      end

      begin
        Costing::RecipeGraphCompleteness.check!(product_recipe)
      rescue Costing::RecipeGraphCompleteness::IncompleteGraphError => e
        raise SyncError, "La receta de \"#{product.name}\" quedó con un grafo incompleto: #{e.message}"
      end

      cost_cents = Costing::ProductRecipeCalculator.unit_cost_cents(product_recipe)
      product.sync_recipe_cost!(cost_cents)
      cost_cents
    end

    private

    attr_reader :product
  end
end
