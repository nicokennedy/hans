# Pantalla inicial del portal. Repartidor: su recorrido de HOY (próxima parada, avance y
# acceso a la lista); si hoy tiene varios repartos, la lista para elegir cuál abrir. Admin: aviso de que la vista del repartidor está en Repartos (vista
# previa, solo lectura).
class Reparto::HomeController < Reparto::BaseController
  def show
    return unless current_user.driver?

    @routes = todays_routes
    @stops_by_route = DeliveryStop.active.where(delivery_route_id: @routes.map(&:id)).includes(order: :customer)
                                  .order(:position, :id).group_by(&:delivery_route_id)
    return unless @routes.one?

    @route = @routes.first
    @stops = @stops_by_route.fetch(@route.id, [])
    @next = @stops.find { |stop| stop.delivery_status == "pending" }
  end
end
