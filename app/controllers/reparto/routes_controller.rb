# Un reparto del día del repartidor, cuando tiene varios (Reparto 1, 2...): la misma pantalla
# que la portada, pero solo con las paradas de ese reparto. Solo sus recorridos de HOY.
class Reparto::RoutesController < Reparto::BaseController
  before_action :require_driver!

  def show
    @route = todays_routes.find { |r| r.id == params[:id].to_i }
    return redirect_to(reparto_root_path, alert: "Ese reparto no es tuyo de hoy.") unless @route

    @stops = @route.active_stops.includes(order: :customer).to_a
    @next = @stops.find { |stop| stop.delivery_status == "pending" }
  end
end
