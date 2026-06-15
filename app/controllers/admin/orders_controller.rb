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
    @products = Product.active.ordered.includes(:category)
  end

  def update
    @order = Order.includes(:order_items).find(params[:id])
    @products = Product.active.ordered.includes(:category)

    ActiveRecord::Base.transaction do
  update_order_items_quantities
  add_new_order_item
  @order.update!(order_params)
end

    redirect_to admin_order_path(@order), notice: "Pedido actualizado correctamente."
  rescue ActiveRecord::RecordInvalid
  @products = Product.active.ordered.includes(:category)
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

    if item_params[:remove] == "1"
      item.destroy!
    else
      item.update!(quantity: item_params[:quantity])
    end
  end
end

def add_new_order_item
  return if params[:new_product_id].blank?
  return if params[:new_quantity].to_i <= 0

  product = Product.find(params[:new_product_id])

  @order.order_items.create!(
    product: product,
    quantity: params[:new_quantity].to_i
  )
end

  def require_admin!
    redirect_to dashboard_path, alert: "No tenés permisos para acceder." unless current_user.admin?
  end
end