# Pantalla inicial del portal. Repartidor: su recorrido de HOY (próxima parada, avance y
# acceso a la lista). Admin: aviso de que la vista del repartidor está en Repartos (vista
# previa, solo lectura).
class Reparto::HomeController < Reparto::BaseController
  def show
    return unless current_user.driver?

    @route = current_user.delivery_routes.find_by(date: Date.current)
    return unless @route

    @stops = @route.active_stops.includes(order: :customer).to_a
    @next = @stops.find { |stop| stop.delivery_status == "pending" }
  end
end
