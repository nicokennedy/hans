class Admin::PaymentsController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin!
  before_action :set_order

  def create
    @payment = @order.payments.build(payment_params)

    if @payment.save
      redirect_to admin_order_path(@order), notice: "Pago registrado correctamente."
    else
      redirect_to admin_order_path(@order), alert: @payment.errors.full_messages.join(", ")
    end
  end

  def destroy
    @order.payments.find(params[:id]).destroy!
    redirect_to admin_order_path(@order), notice: "Pago eliminado correctamente."
  end

  private

  def set_order
    @order = Order.find(params[:order_id])
  end

  def payment_params
    params.require(:payment).permit(:amount, :paid_at, :payment_method, :note)
  end

  def require_admin!
    redirect_to dashboard_path, alert: "No tenés permisos para acceder." unless current_user.admin?
  end
end
