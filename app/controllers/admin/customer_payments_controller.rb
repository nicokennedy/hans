# Pagos de cuenta corriente: un pago global del cliente (ej. una transferencia grande)
# repartido entre varios pedidos. Convive con los pagos por pedido de siempre.
class Admin::CustomerPaymentsController < ApplicationController
  include CustomerAccountParams

  before_action :authenticate_user!
  before_action :require_admin!
  before_action :set_customer

  def new
    prepare_form
    @form = { paid_on: Date.current, payment_method: "bank_transfer", amount: "", reference: "", note: "", allocations: {} }
  end

  def create
    prepare_form(token: params[:request_token])
    amount_cents = CustomerAccounts::Money.parse_pesos(params[:amount])
    paid_on = parse_paid_on(params[:paid_on])
    raw_allocations = params[:allocations].respond_to?(:to_unsafe_h) ? params[:allocations].to_unsafe_h : params[:allocations]
    allocations, parse_errors = parse_allocations(raw_allocations)

    # Sin campos de distribución (cliente sin pedidos pendientes) no hay nada que repartir.
    result = if parse_errors.any?
      CustomerAccounts::Result.new(errors: parse_errors)
    else
      CustomerAccounts::RegisterPayment.call(
        customer: @customer, user: current_user, amount_cents: amount_cents, paid_on: paid_on,
        payment_method: params[:payment_method], allocations: allocations,
        reference: params[:reference], note: params[:note], request_token: params[:request_token]
      )
    end

    if result.ok?
      redirect_to admin_customer_account_path(@customer), notice: success_message(result)
    else
      @errors = result.errors
      @form = { paid_on: paid_on || params[:paid_on], payment_method: params[:payment_method], amount: params[:amount].to_s, reference: params[:reference].to_s, note: params[:note].to_s, allocations: (raw_allocations || {}).to_h }
      render :new, status: :unprocessable_entity
    end
  end

  def void
    payment = @customer.customer_payments.find(params[:id])
    result = CustomerAccounts::VoidPayment.call(customer_payment: payment, user: current_user, reason: params[:reason])

    if result.ok?
      redirect_to admin_customer_account_path(@customer), notice: "Pago anulado. Los saldos de los pedidos se restablecieron."
    else
      redirect_to admin_customer_account_path(@customer), alert: result.errors.join(" ")
    end
  end

  private

  def set_customer
    @customer = Customer.find(params[:customer_id])
  end

  def prepare_form(token: nil)
    @pending_orders = CustomerAccounts::Distribution.pending_orders(@customer).to_a
    @request_token = token.presence || SecureRandom.uuid
    @credit_cents = CustomerAccounts::ApplyCredit.available_cents(@customer)
  end

  def success_message(result)
    base = result.duplicate? ? "Este pago ya estaba registrado (se evitó duplicarlo)." : "Pago registrado."
    return base unless result.credit_cents.to_i.positive?

    "#{base} Quedaron $#{CustomerAccounts::Money.format_pesos(result.credit_cents)} como saldo a favor."
  end
end
