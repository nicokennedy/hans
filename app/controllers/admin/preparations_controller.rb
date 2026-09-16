class Admin::PreparationsController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin!
  before_action :set_preparation, only: [:edit, :update]

  def index
    @preparations = Preparation.order(:name)
  end

  def new
    @preparation = Preparation.new(active: true)
  end

  def create
    @preparation = Preparation.new(preparation_params)

    if @preparation.save
      redirect_to admin_preparations_path, notice: "Preparación creada correctamente."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    load_component_form_data
  end

  def update
    if @preparation.update(preparation_params)
      redirect_to admin_preparations_path, notice: "Preparación actualizada correctamente."
    else
      load_component_form_data
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_preparation
    @preparation = Preparation.find(params[:id])
  end

  # component_costs corre el calculator, que puede levantar
  # CircularDependencyError si (por datos corruptos, nunca por un camino
  # validado normalmente) existiera un ciclo real en la base. Sin este
  # rescue, esa única preparación rota dejaría inalcanzable la propia
  # pantalla de edición que hace falta para arreglarla.
  def load_component_form_data
    @component_costs = @preparation.component_costs
    @total_cost_cents = @preparation.total_cost_cents
    @unit_cost_cents = @preparation.unit_cost_cents
    @cost_calculation_error = nil
  rescue Costing::PreparationCalculator::CircularDependencyError => e
    @component_costs = []
    @total_cost_cents = nil
    @unit_cost_cents = nil
    @cost_calculation_error = e.message
  ensure
    @raw_material_options = RawMaterial.active.order(:name)
    @preparation_options = Preparation.active.where.not(id: @preparation.id)
      .reject { |candidate| candidate.depends_on?(@preparation) }
      .sort_by(&:name)
  end

  # unit_cost_cents/total_cost_cents no existen como columnas — no hay nada
  # que blindar ahí. active default true lo pone el modelo/schema.
  def preparation_params
    params.require(:preparation).permit(:name, :yield_quantity, :yield_unit, :active)
  end
end
