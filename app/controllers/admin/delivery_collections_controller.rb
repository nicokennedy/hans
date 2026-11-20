# R4: administración registra o corrige cobros de un recorrido desde Repartos, antes de
# confirmar el cierre (con motivo al corregir). Usa el mismo servicio que el repartidor
# (DeliveryRoutes::Collections), así todo pasa por la cuenta corriente existente.
class Admin::DeliveryCollectionsController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin!
  before_action :set_route
  before_action :set_collection, only: [:edit, :update]

  def new
    @stops = @route.active_stops.where(kind: "order").includes(order: :customer).to_a
    @stop = @stops.find { |s| s.id == params[:stop_id].to_i }
    @orders = @stop ? DeliveryRoutes::Collections.pending_orders_for(@stop) : []
    @request_token = SecureRandom.uuid
  end

  def create
    stop = @route.active_stops.find(params[:stop_id])
    result = DeliveryRoutes::Collections.new(@route, current_user).record(
      stop: stop, amount_cents: parse_pesos(params[:importe]), allocations: allocations_param,
      unidentified: params[:a_identificar] == "1", request_token: params[:request_token]
    )
    respond(result, "Cobro registrado.", new_admin_delivery_route_collection_path(@route, stop_id: stop.id))
  end

  def edit
    @orders = DeliveryRoutes::Collections.pending_orders_for(@collection.delivery_stop)
    @orders |= Order.where(id: @collection.allocation_map.keys).to_a
    @request_token = SecureRandom.uuid
  end

  def update
    amount = parse_pesos(params[:importe])
    unidentified = params[:a_identificar] == "1"
    result = DeliveryRoutes::Collections.new(@route, current_user).correct(
      @collection, amount_cents: amount, reason: params[:motivo], request_token: params[:request_token],
      allocations: unidentified ? {} : allocations_param, unidentified: unidentified
    )
    respond(result, amount.to_i.zero? ? "Cobro anulado." : "Cobro corregido.", edit_admin_delivery_route_collection_path(@route, @collection))
  end

  private

  def set_route
    @route = DeliveryRoute.find(params[:delivery_route_id])
  end

  def set_collection
    @collection = @route.collections.includes(:customer, delivery_stop: :order).find(params[:id])
  end

  def respond(result, notice, back)
    if result.ok?
      redirect_to admin_delivery_route_path(@route, anchor: "rendicion"), notice: result.already ? "Ya estaba registrado." : notice
    else
      redirect_to back, alert: result.errors.join(" ")
    end
  end

  def allocations_param
    return {} unless params[:asignar].is_a?(ActionController::Parameters)

    params[:asignar].to_unsafe_h.each_with_object({}) do |(id, text), memo|
      cents = parse_pesos(text)
      memo[id.to_i] = cents if cents&.positive?
    end
  end

  def parse_pesos(text)
    CustomerAccounts::Money.parse_pesos(text)
  end
end
