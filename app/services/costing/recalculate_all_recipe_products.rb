module Costing
  # Herramienta de auditoría/reparación — NO es el flujo normal (eso lo
  # cubre la propagación automática). Recorre todos los Product en modo
  # recipe y fuerza un SyncProductCost, uno por uno, sin abortar si alguno
  # falla — así una receta corrupta no bloquea la reparación del resto.
  class RecalculateAllRecipeProducts
    Result = Struct.new(:recalculated, :errors, keyword_init: true)

    def self.call
      new.call
    end

    def call
      recalculated = 0
      errors = []

      Product.where(cost_source: "recipe").find_each do |product|
        begin
          Costing::SyncProductCost.call(product)
          recalculated += 1
        rescue => e
          errors << "Product##{product.id}: #{e.class}: #{e.message}"
        end
      end

      Rails.logger.info(
        "[Costing::RecalculateAllRecipeProducts] recalculated=#{recalculated} errors=#{errors.size}"
      )
      errors.each { |error| Rails.logger.error("[Costing::RecalculateAllRecipeProducts] #{error}") }

      Result.new(recalculated: recalculated, errors: errors)
    end
  end
end
