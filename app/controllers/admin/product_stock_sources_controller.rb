# Vincula un Product con el objeto de stock compartido (Preparation "solo
# stock") del que descuenta al venderse — ver ProductStockSource. Solo admin,
# igual que el resto de la configuración de stock.
class Admin::ProductStockSourcesController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin!
  before_action :set_product

  def create
    source = @product.product_stock_sources.build(source_params)

    if source.save
      redirect_to edit_admin_product_path(@product), notice: "Vínculo de stock agregado."
    else
      redirect_to edit_admin_product_path(@product), alert: source.errors.full_messages.join(", ")
    end
  end

  def destroy
    @product.product_stock_sources.find(params[:id]).destroy!
    redirect_to edit_admin_product_path(@product), notice: "Vínculo de stock eliminado."
  end

  private

  def set_product
    @product = Product.find(params[:product_id])
  end

  def source_params
    params.require(:product_stock_source).permit(:preparation_id, :quantity)
  end
end
