module Costing
  # Punto único de propagación: dado lo que cambió (una RawMaterial, una
  # Preparation, o una ProductRecipe), descubre qué ProductRecipes dependen
  # de eso — directa o transitivamente — y sincroniza los Product en modo
  # recipe correspondientes (Costing::SyncProductCost).
  #
  # Deliberadamente NO atrapa errores de sincronización y sigue de largo:
  # si CUALQUIER producto afectado no puede sincronizarse, levanta
  # PropagationError. Quien llama a este service lo hace siempre dentro de
  # una transacción junto con el cambio que lo disparó (ver
  # RawMaterials::UpdateWithCostHistory, CostPropagating) — así una falla
  # acá revierte todo, y nunca queda un Product#cost_cents desactualizado
  # después de una operación que el usuario vio como exitosa.
  class PropagateCostChange
    class PropagationError < StandardError; end

    Result = Struct.new(:product_recipes, :synced_product_ids, keyword_init: true)

    def self.call(changed_entity)
      new.call(changed_entity)
    end

    def call(changed_entity)
      product_recipes = discover_affected_product_recipes(changed_entity)
      recipe_sourced = product_recipes.select { |product_recipe| product_recipe.product.recipe? }

      synced_ids = []
      failures = []

      recipe_sourced.each do |product_recipe|
        begin
          Costing::SyncProductCost.call(product_recipe.product)
          synced_ids << product_recipe.product_id
        rescue => e
          failures << "Product##{product_recipe.product_id}: #{e.class}: #{e.message}"
        end
      end

      log(changed_entity, product_recipes, synced_ids, failures)

      if failures.any?
        raise PropagationError, "No se pudo actualizar el costo de: #{failures.join('; ')}"
      end

      Result.new(product_recipes: product_recipes, synced_product_ids: synced_ids)
    end

    private

    def discover_affected_product_recipes(changed_entity)
      case changed_entity
      when RawMaterial
        expand_owners(owners_using(changed_entity))
      when Preparation
        expand_owners(owners_using(changed_entity))
      when ProductRecipe
        [ changed_entity ]
      else
        []
      end.uniq
    end

    # Quién usa "component" (RawMaterial o Preparation) como ingrediente en
    # alguna línea — sus owners son Preparation y/o ProductRecipe.
    def owners_using(component)
      RecipeComponent.where(component: component).includes(:owner).map(&:owner).compact
    end

    # Sube el grafo desde una lista de owners hasta las ProductRecipe
    # terminales. Un ProductRecipe encontrado se agrega directo (no puede
    # tener nada arriba, nunca es component de nadie). Una Preparation
    # encontrada se resuelve un nivel más arriba, recursivamente. visited
    # evita recalcular/recorrer dos veces el mismo nodo y protege contra un
    # ciclo corrupto en el grafo de Preparations (nunca debería existir uno
    # validado, pero esto no confía en eso).
    def expand_owners(owners, visited = Set.new)
      result = []

      owners.each do |owner|
        key = "#{owner.class.name}:#{owner.id}"
        next if visited.include?(key)

        visited << key

        case owner
        when ProductRecipe
          result << owner
        when Preparation
          result.concat(expand_owners(owners_using(owner), visited))
        end
      end

      result
    end

    def log(changed_entity, product_recipes, synced_ids, failures)
      source_label = changed_entity.respond_to?(:id) ? "#{changed_entity.class.name}##{changed_entity.id}" : changed_entity.class.name
      Rails.logger.info(
        "[Costing::PropagateCostChange] source=#{source_label} " \
        "affected_product_recipes=#{product_recipes.size} synced_products=#{synced_ids.size} errors=#{failures.size}"
      )
      failures.each { |failure| Rails.logger.error("[Costing::PropagateCostChange] #{failure}") }
    end
  end
end
