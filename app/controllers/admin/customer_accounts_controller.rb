# Cuenta corriente de un cliente: resumen de deuda, pedidos, historial de pagos y
# acciones (+ Registrar pago, aplicar saldo a favor, anular). Solo admin, igual que los
# pagos por pedido.
class Admin::CustomerAccountsController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin!

  def show
    @customer = Customer.find(params[:customer_id])
    @summary = CustomerAccounts::Summary.new(@customer, filter: params[:filter], from: params[:from], to: params[:to])
  end
end
