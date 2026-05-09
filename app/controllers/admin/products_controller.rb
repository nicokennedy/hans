class Admin::ProductsController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin!
  before_action :set_product, only: [:edit, :update, :destroy]

  def index
    @products = Product.includes(:category).ordered
  end

  def new
    @product = Product.new(active: true)
  end

  def create
    @product = Product.new(product_params)

    if @product.save
      redirect_to admin_products_path, notice: "Producto creado correctamente."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @product.update(product_params)
      redirect_to admin_products_path, notice: "Producto actualizado correctamente."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @product.destroy
    redirect_to admin_products_path, notice: "Producto eliminado correctamente."
  end

  private

  def set_product
    @product = Product.find(params[:id])
  end

  def product_params
    params.require(:product).permit(
      :name,
      :description,
      :price_amount,
    	:cost_amount,
      :category_id,
      :position,
      :active
    )
  end

  def require_admin!
    redirect_to dashboard_path, alert: "No tenés permisos para acceder." unless current_user.admin?
  end
end