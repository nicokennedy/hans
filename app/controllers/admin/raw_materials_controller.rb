class Admin::RawMaterialsController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin!
  before_action :set_raw_material, only: [:edit, :update]

  def index
    @raw_materials = RawMaterial.order(:name)
  end

  def new
    @raw_material = RawMaterial.new(active: true)
  end

  def create
    @raw_material = RawMaterial.new(raw_material_params)

    if @raw_material.save
      redirect_to admin_raw_materials_path, notice: "Materia prima creada correctamente."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @cost_changes = @raw_material.cost_changes.order(created_at: :desc)
  end

  def update
    RawMaterials::UpdateWithCostHistory.call(
      raw_material: @raw_material,
      attributes: raw_material_params,
      changed_by: current_user
    )

    redirect_to admin_raw_materials_path, notice: "Materia prima actualizada correctamente."
  rescue ActiveRecord::RecordInvalid
    @cost_changes = @raw_material.cost_changes.order(created_at: :desc)
    render :edit, status: :unprocessable_entity
  end

  private

  def set_raw_material
    @raw_material = RawMaterial.find(params[:id])
  end

  # unit_cost_cents deliberadamente afuera: nunca es un parámetro aceptado,
  # ni desde este form ni desde ningún otro cliente HTTP — el modelo lo
  # recalcula siempre en before_validation, pero esto blinda además la capa
  # de parámetros.
  def raw_material_params
    params.require(:raw_material).permit(
      :name,
      :category,
      :brand,
      :supplier,
      :purchase_price_amount,
      :purchase_quantity,
      :purchase_unit,
      :base_unit,
      :active
    )
  end
end
