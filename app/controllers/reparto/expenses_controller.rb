# R4: gastos pagados con el efectivo del reparto (nafta, estacionamiento...). Con confirmación
# antes de guardar. El repartidor no puede gastar más que el efectivo disponible del recorrido
# (DeliveryRoutes::Expenses). Corregir: con motivo, hasta enviar la rendición.
class Reparto::ExpensesController < Reparto::BaseController
  before_action :require_driver!
  before_action :set_route
  before_action :set_expense, only: [:edit, :confirm_correction, :correct]

  def index
    @summary = DeliveryRoutes::Settlement.new(@route)
  end

  def new
    @summary = DeliveryRoutes::Settlement.new(@route)
  end

  def confirm
    @concept = concept_param
    @amount_cents = parse_pesos(params[:importe])
    errors = []
    errors << "Elegí o escribí qué pagaste." if @concept.blank?
    errors << "Escribí el importe." unless @amount_cents&.positive?
    available = DeliveryRoutes::Settlement.new(@route).available_cents
    errors << "Supera lo que cobraste (#{helpers.format_money(available)}). Avisale a administración." if @amount_cents.to_i > available
    return redirect_to(reparto_route_new_expense_path(@route, params.permit(:concepto, :concepto_texto, :importe, :notas).to_h), alert: errors.join(" ")) if errors.any?

    @request_token = SecureRandom.uuid
  end

  def create
    result = DeliveryRoutes::Expenses.new(@route, current_user).record(
      concept: concept_param, amount_cents: parse_pesos(params[:importe]), notes: params[:notas], request_token: params[:request_token]
    )
    if result.ok?
      redirect_to reparto_route_expenses_path(@route), notice: result.already ? "Ese gasto ya estaba guardado." : "Listo: el gasto quedó guardado."
    else
      redirect_to reparto_route_new_expense_path(@route), alert: result.errors.join(" ")
    end
  end

  def edit
  end

  def confirm_correction
    @amount_cents = parse_pesos(params[:importe])
    @reason = params[:motivo].to_s.squish
    errors = []
    errors << "Escribí el importe correcto (0 para anularlo)." if @amount_cents.nil?
    errors << "Escribí el motivo." if @reason.blank?
    errors << "Es el mismo importe: no hay nada que corregir." if @amount_cents == @expense.amount_cents
    return redirect_to(reparto_route_expense_correction_path(@route, @expense), alert: errors.join(" ")) if errors.any?

    @request_token = SecureRandom.uuid
  end

  def correct
    result = DeliveryRoutes::Expenses.new(@route, current_user).correct(
      @expense, concept: @expense.concept, amount_cents: parse_pesos(params[:importe]), reason: params[:motivo], request_token: params[:request_token]
    )
    if result.ok?
      redirect_to reparto_route_expenses_path(@route), notice: "Listo: el gasto quedó corregido."
    else
      redirect_to reparto_route_expense_correction_path(@route, @expense), alert: result.errors.join(" ")
    end
  end

  private

  def set_route
    @route = find_driver_route(params[:route_id])
  end

  def set_expense
    @expense = @route.expenses.find(params[:id])
    redirect_to reparto_route_expenses_path(@route), alert: "Ese gasto ya fue corregido." if @expense.voided?
  end

  def concept_param
    choice = params[:concepto].to_s
    (choice == "Otro" ? params[:concepto_texto] : choice).to_s.squish.first(80).presence
  end
end
