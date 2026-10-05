require "bigdecimal"

module Stock
  # Para 1 unidad de un Product vendido, ¿cuánto consume de cada StockItem
  # activo? Recorre el mismo grafo de recetas que ya usa Costing (ProductRecipe
  # -> RecipeComponent -> Preparation, anidable), pero en vez de acumular
  # costo acumula cantidad física, y CORTA el recorrido apenas encuentra un
  # StockItem activo — no sigue bajando más allá de un ítem que ya se
  # controla como unidad física propia (producirlo es una acción manual
  # aparte, no algo que se derive automáticamente de la receta).
  #
  # Además de la receta, un Product puede descontar de objetos de stock
  # compartidos configurados a mano (ProductStockSource): es lo que permite
  # que, por ejemplo, 3 alfajores distintos descuenten del mismo "Tapas
  # Alfajor Almendra" sin tocar su receta ni su costo.
  #
  # RawMaterial nunca es relevante acá — este módulo no controla materia
  # prima, solo Preparation/Product.
  class ProductConsumption
    def self.call(product)
      new.call(product)
    end

    def call(product)
      result = Hash.new(BigDecimal(0))

      own_stock_item = active_stock_item_for(product)
      if own_stock_item
        result[own_stock_item] = BigDecimal(1)
        return result
      end

      add_explicit_sources(product, result)

      product_recipe = product.product_recipe
      return result if product_recipe.blank? || product_recipe.yield_quantity.to_d.zero?

      accumulate(product_recipe.recipe_components, BigDecimal(1) / product_recipe.yield_quantity.to_d, result, [])
      result
    end

    private

    # Objetos de stock compartidos configurados a mano para este producto
    # (ProductStockSource), ej. 1 un de "Tapas Alfajor Almendra" por alfajor.
    # Son aparte de la receta: una preparación stock_only no puede ser
    # ingrediente de ninguna receta (ver RecipeComponent), así que nunca
    # colisiona con lo que suma `accumulate`. Si el StockItem no existe o está
    # inactivo, el vínculo simplemente no descuenta nada.
    def add_explicit_sources(product, result)
      product.product_stock_sources.includes(preparation: :stock_item).each do |source|
        stock_item = active_stock_item_for(source.preparation)
        result[stock_item] += source.quantity.to_d if stock_item
      end
    end

    # factor = cuántas yield-units del dueño de recipe_components corresponden
    # a 1 unidad del Product raíz. path protege contra un ciclo corrupto en
    # el grafo de Preparations (nunca debería existir uno validado, pero no
    # confía en eso — mismo criterio defensivo que PreparationCalculator).
    def accumulate(recipe_components, factor, result, path)
      recipe_components.includes(:component).each do |recipe_component|
        component = recipe_component.component
        next unless component.is_a?(Preparation)

        quantity_in_component_unit = Measurement::UnitConverter.convert(
          recipe_component.quantity, from: recipe_component.unit, to: component.yield_unit
        )
        contribution = quantity_in_component_unit * factor

        stock_item = active_stock_item_for(component)
        if stock_item
          result[stock_item] += contribution
        else
          next if component.id.present? && path.include?(component.id)
          next if component.yield_quantity.to_d.zero?

          accumulate(component.recipe_components, contribution / component.yield_quantity.to_d, result, path + [component.id])
        end
      end
    end

    def active_stock_item_for(stockable)
      item = stockable.stock_item
      item&.active? ? item : nil
    end
  end
end
