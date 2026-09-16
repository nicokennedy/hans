module Costing
  # Activa el costeo por receta de un Product: valida que la ProductRecipe
  # esté completa y sea calculable, calcula su costo unitario, y recién ahí
  # cambia cost_source a "recipe" y escribe cost_cents — todo atómico, todo
  # o nada. Si algo falla, el Product queda exactamente como estaba (ni
  # cost_source ni cost_cents cambian).
  class ActivateProductRecipe
    class ActivationError < StandardError; end

    def self.call(product)
      new(product).call
    end

    def initialize(product)
      @product = product
    end

    def call
      product_recipe = product.product_recipe
      raise ActivationError, "El producto no tiene una receta creada" if product_recipe.blank?

      unless product_recipe.yield_quantity.present? && product_recipe.yield_quantity.to_d.positive?
        raise ActivationError, "La receta necesita un rendimiento (yield) mayor a cero"
      end

      begin
        Costing::RecipeGraphCompleteness.check!(product_recipe)
      rescue Costing::RecipeGraphCompleteness::IncompleteGraphError => e
        raise ActivationError, e.message
      end

      cost_cents =
        begin
          Costing::ProductRecipeCalculator.unit_cost_cents(product_recipe)
        rescue Measurement::UnitConverter::UnknownUnitError, Measurement::UnitConverter::IncompatibleUnitsError,
               Costing::PreparationCalculator::CircularDependencyError => e
          raise ActivationError, "La receta no se puede calcular: #{e.message}"
        end

      ActiveRecord::Base.transaction(requires_new: true) do
        product.activate_recipe_cost!(cost_cents)
      end

      cost_cents
    end

    private

    attr_reader :product
  end
end
