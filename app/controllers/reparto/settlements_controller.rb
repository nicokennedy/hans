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
    if result.ok? && past_route?(@route)
      # Un reparto de un día anterior deja de estar en el portal al enviarlo: se confirma en la portada.
      to_deliver = DeliveryRoutes::Settlement.new(@route).to_deliver_cents
      redirect_to reparto_root_path, notice: "Listo: enviaste la rendición del #{@route.label} del #{l(@route.date, format: '%d/%m')}. Entregá #{helpers.format_money(to_deliver)} a administración."
    elsif result.ok?
      redirect_to reparto_route_settlement_path(@route), notice: result.already ? "La rendición ya estaba enviada." : "Listo: enviaste la rendición a administración."
    else
      redirect_to reparto_route_settlement_path(@route), alert: result.errors.join(" ")
    end
  end

  private

  def set_route
    @route = find_driver_route(params[:route_id])
  end
end
