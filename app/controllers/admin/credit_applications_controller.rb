# Aplicación explícita del saldo a favor de un cliente a sus pedidos pendientes.
class Admin::CreditApplicationsController < ApplicationController
  include CustomerAccountParams

  before_action :authenticate_user!
  before_action :require_admin!
  before_action :set_customer

  def new
    prepare_form
    @allocations = {}
  end

  def create
    prepare_form
    raw = params[:allocations].respond_to?(:to_unsafe_h) ? params[:allocations].to_unsafe_h : params[:allocations]
    allocations, parse_errors = parse_allocations(raw)

    result = if parse_errors.any?
      CustomerAccounts::Result.new(errors: parse_errors)
    else
      CustomerAccounts::ApplyCredit.call(customer: @customer, user: current_user, allocations: allocations)
    end

    if result.ok?
      redirect_to admin_customer_account_path(@customer), notice: "Saldo a favor aplicado. Te quedan $#{CustomerAccounts::Money.format_pesos(result.credit_cents)} de saldo a favor."
    else
      @errors = result.errors
      @allocations = (raw || {}).to_h
      render :new, status: :unprocessable_entity
    end
  end

  def revert
    payment = Payment.joins(:order).where(orders: { customer_id: @customer.id }).find(params[:id])
    result = CustomerAccounts::RevertCreditApplication.call(payment: payment, user: current_user, reason: params[:reason])

    if result.ok?
      redirect_to admin_customer_account_path(@customer), notice: "Aplicación revertida: el importe volvió al saldo a favor y el pedido recuperó su saldo."
    else
      redirect_to admin_customer_account_path(@customer), alert: result.errors.join(" ")
    end
  end

  private

  def set_customer
    @customer = Customer.find(params[:customer_id])
  end

  def prepare_form
    @pending_orders = CustomerAccounts::Distribution.pending_orders(@customer).to_a
    @credit_cents = CustomerAccounts::ApplyCredit.available_cents(@customer)
  end
end
