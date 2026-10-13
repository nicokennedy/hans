# Pagos de un pedido minorista (solo admin). Cuenta propia: independiente de los pagos y la
# cuenta corriente mayoristas. No hay borrado: un pago se anula con motivo (auditable).
class Admin::RetailOrderPaymentsController < ApplicationController
  include RetailNavigationContext

  before_action :authenticate_user!
  before_action :require_admin!
  before_action :set_order

  def new
    @form = { paid_at: Date.current, payment_method: @order.planned_payment_method || "transfer", amount: "", notes: "", allow_excess: false }
    @token = SecureRandom.hex(16)
  end

  def create
    result = Retail::RegisterPayment.call(
      order: @order, user: current_user, amount: params[:amount], paid_at: params[:paid_at], payment_method: params[:payment_method],
      notes: params[:notes], allow_excess: params[:allow_excess], request_token: params[:request_token]
    )

    if result.ok?
      notice = result.duplicate? ? "Ese pago ya estaba registrado." : "Pago registrado."
      redirect_to admin_retail_order_path(@order, retail_context), notice: notice
    else
      @errors = result.errors
      @form = { paid_at: params[:paid_at], payment_method: params[:payment_method], amount: params[:amount].to_s, notes: params[:notes].to_s, allow_excess: params[:allow_excess].present? }
      @token = params[:request_token].presence || SecureRandom.hex(16)
      render :new, status: :unprocessable_entity
    end
  end

  def void
    payment = @order.retail_order_payments.find(params[:id])
    result = Retail::VoidPayment.call(payment: payment, user: current_user, reason: params[:reason])

    if result.ok?
      redirect_to admin_retail_order_path(@order, retail_context), notice: "Pago anulado. El saldo se recalculó."
    else
      redirect_to admin_retail_order_path(@order, retail_context), alert: result.errors.join(" ")
    end
  end

  private

  def set_order
    @order = RetailOrder.find(params[:retail_order_id])
  end
end
