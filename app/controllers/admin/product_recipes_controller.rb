class Admin::ProductRecipesController < ApplicationController
  include CostPropagating

  before_action :authenticate_user!
  before_action :require_admin!
  before_action :set_product

  def new
    @product_recipe = @product.build_product_recipe
  end

  def create
    @product_recipe = @product.build_product_recipe(product_recipe_params)

    if @product_recipe.save
      redirect_to edit_admin_product_product_recipe_path(@product), notice: "Receta creada. Agregale componentes y activala cuando esté lista."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @product_recipe = @product.product_recipe
    load_component_form_data
  end

  # yield_quantity es lo único editable acá — siempre amerita propagar si
  # el producto está en modo recipe (si es manual, propagate_after igual
  # corre pero Costing::SyncProductCost no toca nada, ver su guard clause).
  def update
    @product_recipe = @product.product_recipe

    saved = propagate_after(@product_recipe) { @product_recipe.update(product_recipe_params) }

    if saved
      redirect_to edit_admin_product_product_recipe_path(@product), notice: "Receta actualizada."
    else
      @product_recipe.reload if @cost_propagation_error
      load_component_form_data
      flash.now[:alert] = @cost_propagation_error if @cost_propagation_error
      render :edit, status: :unprocessable_entity
    end
  end

  def activate
    Costing::ActivateProductRecipe.call(@product)
    @product.reload
    redirect_to edit_admin_product_path(@product), notice: "Costo por receta activado. Costo actual: #{helpers.format_money(@product.cost_cents)}"
  rescue Costing::ActivateProductRecipe::ActivationError => e
    redirect_to edit_admin_product_product_recipe_path(@product), alert: e.message
  end

  def deactivate
    Costing::DeactivateProductRecipe.call(@product)
    @product.reload
    redirect_to edit_admin_product_path(@product), notice: "Costo manual activado. Se conservó #{helpers.format_money(@product.cost_cents)} como costo actual."
  end

  private

  def set_product
    @product = Product.find(params[:product_id])
  end

  def load_component_form_data
    @component_costs = @product_recipe.component_costs
    @total_cost_cents = @product_recipe.total_cost_cents
    @unit_cost_cents = @product_recipe.unit_cost_cents
    @cost_calculation_error = nil
  rescue Costing::PreparationCalculator::CircularDependencyError, Measurement::UnitConverter::UnknownUnitError,
         Measurement::UnitConverter::IncompatibleUnitsError => e
    @component_costs = []
    @total_cost_cents = nil
    @unit_cost_cents = nil
    @cost_calculation_error = e.message
  ensure
    @raw_material_options = RawMaterial.active.order(:name)
    @preparation_options = Preparation.active.order(:name)
  end

  def product_recipe_params
    params.require(:product_recipe).permit(:yield_quantity)
  end
end
