# R4: "Mi rendición" de UN recorrido (cada reparto del día tiene la suya). El total lo calcula
# HANS (cobros − gastos); el repartidor no lo puede cambiar. Al enviarla, cobros y gastos
# quedan cerrados para él.
class Reparto::SettlementsController < Reparto::BaseController
  before_action :require_driver!
  before_action :set_route

  def show
    @summary = DeliveryRoutes::Settlement.new(@route)
  end

  def confirm
    return redirect_to(reparto_route_settlement_path(@route)) unless @route.open_for_driver?

    @summary = DeliveryRoutes::Settlement.new(@route)
  end

  def submit
    result = DeliveryRoutes::Settlements.new(@route, current_user).submit
    if result.ok?
      redirect_to reparto_route_settlement_path(@route), notice: result.already ? "La rendición ya estaba enviada." : "Listo: enviaste la rendición a administración."
    else
      redirect_to reparto_route_settlement_path(@route), alert: result.errors.join(" ")
    end
  end

  private

  def set_route
    @route = find_todays_route(params[:route_id])
  end
end
