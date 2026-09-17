module Admin::RecipesHelper
  # Sin receta: el Product no tiene ProductRecipe todavía.
  # Borrador: tiene ProductRecipe, pero Product#cost_source sigue "manual"
  # — la receta no gobierna el costo del producto (puede estar incompleta).
  # Activa: tiene ProductRecipe y Product#cost_source == "recipe" — la
  # receta gobierna Product#cost_cents.
  def recipe_state(product)
    return :none if product.product_recipe.blank?

    product.recipe? ? :active : :draft
  end

  def recipe_state_label(product)
    case recipe_state(product)
    when :none then "Sin receta"
    when :draft then "Borrador"
    when :active then "Activa"
    end
  end

  def recipe_state_badge_class(product)
    case recipe_state(product)
    when :none then "bg-secondary"
    when :draft then "bg-warning text-dark"
    when :active then "bg-success"
    end
  end

  def recipe_action_label(product)
    recipe_state(product) == :none ? "Crear receta" : "Editar receta"
  end

  def recipe_action_path(product)
    if recipe_state(product) == :none
      new_admin_product_product_recipe_path(product)
    else
      edit_admin_product_product_recipe_path(product)
    end
  end
end
