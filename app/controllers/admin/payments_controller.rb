class Admin::PaymentsController < ApplicationController
  include OrdersNavigationContext

  before_action :authenticate_user!
  before_action :require_admin!
  before_action :set_order

  def create
    @payment = @order.payments.build(payment_params)
    @payment.user = current_user

    # Con el pedido bloqueado, dos pagos simultáneos no pueden exceder su saldo (el
    # pago de cuenta corriente también bloquea los pedidos que reparte).
    saved = @order.with_lock { @payment.save }

    if saved
      redirect_to admin_order_path(@order, orders_context), notice: "Pago registrado correctamente."
    else
      redirect_to admin_order_path(@order, orders_context), alert: @payment.errors.full_messages.join(", ")
    end
  end

  def destroy
    payment = @order.payments.find(params[:id])

    if payment.customer_payment_id
      redirect_to admin_order_path(@order, orders_context), alert: "Este pago pertenece a un pago de cuenta corriente: anulalo desde la cuenta corriente del cliente."
      return
    end

    payment.destroy!
    redirect_to admin_order_path(@order, orders_context), notice: "Pago eliminado correctamente."
  end

  private

  def set_order
    @order = Order.find(params[:order_id])
  end

  def payment_params
    params.require(:payment).permit(:amount, :paid_at, :payment_method, :note)
  end
end
