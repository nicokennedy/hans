# Mismo patrón que Admin::RecipeComponentsController pero para los
# componentes de una ProductRecipe en vez de una Preparation — ver ese
# controller para el razonamiento detallado (RecipeComponent es el mismo
# modelo polimórfico para ambos casos).
class Admin::ProductRecipeComponentsController < ApplicationController
  include CostPropagating

  before_action :authenticate_user!
  before_action :require_admin!
  before_action :set_product_recipe

  def create
    component = find_component(params.dig(:recipe_component, :component_ref))
    @recipe_component = @product_recipe.recipe_components.new(
      component: component,
      quantity: params.dig(:recipe_component, :quantity),
      unit: params.dig(:recipe_component, :unit)
    )

    saved = component.present? && propagate_after(@product_recipe) { @recipe_component.save }

    if saved
      redirect_to edit_admin_product_product_recipe_path(@product), notice: "Componente agregado."
    else
      redirect_to edit_admin_product_product_recipe_path(@product), alert: component_error_message(@recipe_component, component)
    end
  end

  def update
    recipe_component = @product_recipe.recipe_components.find(params[:id])

    if propagate_after(@product_recipe) { recipe_component.update(recipe_component_params) }
      redirect_to edit_admin_product_product_recipe_path(@product), notice: "Componente actualizado."
    else
      alert = @cost_propagation_error || recipe_component.errors.full_messages.join(", ")
      redirect_to edit_admin_product_product_recipe_path(@product), alert: alert
    end
  end

  def destroy
    recipe_component = @product_recipe.recipe_components.find(params[:id])

    if propagate_after(@product_recipe) { recipe_component.destroy! }
      redirect_to edit_admin_product_product_recipe_path(@product), notice: "Componente eliminado de la receta."
    else
      redirect_to edit_admin_product_product_recipe_path(@product), alert: @cost_propagation_error || "No se pudo eliminar el componente."
    end
  end

  private

  def set_product_recipe
    @product = Product.find(params[:product_id])
    @product_recipe = @product.product_recipe
  end

  def recipe_component_params
    params.require(:recipe_component).permit(:quantity, :unit)
  end

  def find_component(component_ref)
    type, id = component_ref.to_s.split(":", 2)
    return nil unless RecipeComponent::ALLOWED_COMPONENT_TYPES.include?(type)

    type.constantize.find_by(id: id)
  end

  def component_error_message(recipe_component, component)
    return "Seleccioná una materia prima o preparación válida." if component.blank?

    recipe_component.errors.full_messages.join(", ")
  end
end
