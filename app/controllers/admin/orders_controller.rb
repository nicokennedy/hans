class Admin::OrdersController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin!

  def index
    @orders = Order.includes(:customer).order(created_at: :desc)
  end

  def show
    @order = Order.includes(:customer, order_items: :product).find(params[:id])
  end

  private

  def require_admin!
    redirect_to dashboard_path, alert: "No tenés permisos para acceder." unless current_user.admin?
  end
end