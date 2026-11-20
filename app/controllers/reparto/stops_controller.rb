# R3: el repartidor recorre SUS recorridos del día y registra entregas. Solo el repartidor
# asignado: las paradas se buscan dentro de sus recorridos de hoy (puede tener varios: cada
# parada pertenece a uno solo y la pantalla muestra solo las de ese reparto), así que nunca ve ni toca las
# de otro repartidor ni de otro día. El admin mira desde Repartos → "Ver como repartidor"
# (solo lectura), no desde acá. Toda acción es idempotente (DeliveryRoutes::Deliveries).
class Reparto::StopsController < Reparto::BaseController
  before_action :require_driver!
  before_action :require_routes
  before_action :set_route, only: [:index]
  before_action :set_stop, except: [:index]

  rescue_from ActiveRecord::RecordNotFound do
    redirect_to reparto_root_path, alert: "Esa parada ya no está en tu recorrido de hoy."
  end

  def index
    @stops = @route.active_stops.includes(order: :customer).to_a
  end

  def show
  end

  def deliver
    respond_with DeliveryRoutes::Deliveries.new(@stop, current_user).deliver
  end

  def not_delivered
  end

  def record_not_delivered
    respond_with DeliveryRoutes::Deliveries.new(@stop, current_user).not_delivered(params[:reason])
  end

  def done
    respond_with DeliveryRoutes::Deliveries.new(@stop, current_user).done
  end

  def saved
    @next = @route.active_stops.pending_delivery.where.not(id: @stop.id).first
  end

  private

  def require_routes
    redirect_to reparto_root_path if todays_routes.empty?
  end

  # /reparto/repartos/:route_id/paradas. Sin route_id (enlace viejo) solo si hoy hay un único reparto.
  def set_route
    @route = params[:route_id] ? todays_routes.find { |r| r.id == params[:route_id].to_i } : (todays_routes.first if todays_routes.one?)
    redirect_to reparto_root_path unless @route
  end

  def set_stop
    @stop = DeliveryStop.active.where(delivery_route_id: todays_routes.map(&:id))
                        .includes(order: [:customer, :order_items]).find(params[:id])
    @route = todays_routes.find { |r| r.id == @stop.delivery_route_id }
  end

  def respond_with(result)
    if result.ok?
      redirect_to saved_reparto_stop_path(@stop, ya: (result.already ? 1 : nil))
    else
      redirect_to reparto_stop_path(@stop), alert: result.errors.join(" ")
    end
  end
end
