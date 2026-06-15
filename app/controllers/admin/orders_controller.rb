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
    @order = Order.includes(:customer, order_items: :product).find(params[:id])
  end

  def update
    @order = Order.includes(:order_items).find(params[:id])

    ActiveRecord::Base.transaction do
      update_order_items_quantities
      @order.update!(order_params)
    end

    redirect_to admin_order_path(@order), notice: "Pedido actualizado correctamente."
  rescue ActiveRecord::RecordInvalid
    render :edit, status: :unprocessable_entity
  end

  private

  def order_params
    params.require(:order).permit(
      :delivery_date,
      :status,
      :customer_comment
    )
  end

  def update_order_items_quantities
    return unless params[:order_items].present?

    params[:order_items].each do |id, item_params|
      item = @order.order_items.find(id)
      item.update!(quantity: item_params[:quantity])
    end
  end

  def require_admin!
    redirect_to dashboard_path, alert: "No tenés permisos para acceder." unless current_user.admin?
  end
end