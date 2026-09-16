class Admin::RecipeComponentsController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin!
  before_action :set_preparation

  def create
    component = find_component(params.dig(:recipe_component, :component_ref))
    @recipe_component = @preparation.recipe_components.new(
      component: component,
      quantity: params.dig(:recipe_component, :quantity),
      unit: params.dig(:recipe_component, :unit)
    )

    if component.present? && @recipe_component.save
      redirect_to edit_admin_preparation_path(@preparation), notice: "Componente agregado."
    else
      redirect_to edit_admin_preparation_path(@preparation), alert: component_error_message(@recipe_component, component)
    end
  end

  # Solo cantidad/unidad son editables acá — cambiar A QUÉ apunta la línea
  # no tiene UI (se borra y se agrega de nuevo); el modelo igual valida
  # ciclos ante cualquier update, sea cual sea el origen.
  def update
    recipe_component = @preparation.recipe_components.find(params[:id])

    if recipe_component.update(recipe_component_params)
      redirect_to edit_admin_preparation_path(@preparation), notice: "Componente actualizado."
    else
      redirect_to edit_admin_preparation_path(@preparation), alert: recipe_component.errors.full_messages.join(", ")
    end
  end

  def destroy
    # Solo elimina la línea de la receta — nunca la RawMaterial/Preparation
    # que referenciaba. "esta preparación ya no usa este ingrediente", no
    # "borrar el ingrediente".
    @preparation.recipe_components.find(params[:id]).destroy!
    redirect_to edit_admin_preparation_path(@preparation), notice: "Componente eliminado de la preparación."
  end

  private

  def set_preparation
    @preparation = Preparation.find(params[:preparation_id])
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
