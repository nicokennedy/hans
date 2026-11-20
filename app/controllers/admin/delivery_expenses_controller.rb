# R4: administración registra o corrige gastos de un recorrido antes del cierre. Un gasto mayor
# al efectivo disponible solo entra como excepción explícita con motivo (DeliveryRoutes::Expenses).
class Admin::DeliveryExpensesController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin!
  before_action :set_route
  before_action :set_expense, only: [:edit, :update]

  def new
    @summary = DeliveryRoutes::Settlement.new(@route)
    @request_token = SecureRandom.uuid
  end

  def create
    result = DeliveryRoutes::Expenses.new(@route, current_user).record(
      concept: params[:concepto], amount_cents: parse_pesos(params[:importe]), notes: params[:notas], request_token: params[:request_token],
      exception: params[:excepcion] == "1", exception_reason: params[:motivo_excepcion]
    )
    respond(result, "Gasto registrado.", new_admin_delivery_route_expense_path(@route))
  end

  def edit
    @summary = DeliveryRoutes::Settlement.new(@route)
    @request_token = SecureRandom.uuid
  end

  def update
    amount = parse_pesos(params[:importe])
    result = DeliveryRoutes::Expenses.new(@route, current_user).correct(
      @expense, concept: params[:concepto].presence || @expense.concept, amount_cents: amount, notes: params[:notas], reason: params[:motivo],
      request_token: params[:request_token], exception: params[:excepcion] == "1", exception_reason: params[:motivo_excepcion]
    )
    respond(result, amount.to_i.zero? ? "Gasto anulado." : "Gasto corregido.", edit_admin_delivery_route_expense_path(@route, @expense))
  end

  private

  def set_route
    @route = DeliveryRoute.find(params[:delivery_route_id])
  end

  def set_expense
    @expense = @route.expenses.find(params[:id])
  end

  def respond(result, notice, back)
    if result.ok?
      redirect_to admin_delivery_route_path(@route, anchor: "rendicion"), notice: result.already ? "Ya estaba registrado." : notice
    else
      redirect_to back, alert: result.errors.join(" ")
    end
  end

  def parse_pesos(text)
    CustomerAccounts::Money.parse_pesos(text)
  end
end
