class Admin::OrdersController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin!

  def index
    @orders = Order.includes(:customer).order(created_at: :desc)
  end

  def show
    @order = Order.includes(:customer, order_items: :product).find(params[:id])
  end

  def edit
    @order = Order.includes(order_items: :product).find(params[:id])
  end

  def update
    @order = Order.find(params[:id])

    if @order.update(order_params)
      redirect_to admin_order_path(@order), notice: "Pedido actualizado correctamente."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def order_params
    params.require(:order).permit(
      :delivery_date,
      :status,
      :customer_comment
    )
  end

  def require_admin!
    redirect_to dashboard_path, alert: "No tenés permisos para acceder." unless current_user.admin?
  end
end