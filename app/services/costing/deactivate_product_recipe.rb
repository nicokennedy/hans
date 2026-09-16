module Costing
  # Vuelve un Product a costeo manual. La ProductRecipe NO se borra — queda
  # guardada, reactivable después. cost_cents se conserva tal cual estaba
  # (el último costo calculado por receta pasa a ser el punto de partida
  # manual), a propósito: es lo que pidió el negocio.
  class DeactivateProductRecipe
    def self.call(product)
      new(product).call
    end

    def initialize(product)
      @product = product
    end

    def call
      ActiveRecord::Base.transaction(requires_new: true) do
        product.deactivate_recipe_cost!
      end

      product.cost_cents
    end

    private

    attr_reader :product
  end
end
