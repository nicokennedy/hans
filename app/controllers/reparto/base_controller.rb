# Portal del repartidor (/reparto). Pensado para el iPhone corporativo y para una persona con
# poca experiencia con sistemas: layout propio, sin menú lateral ni pantallas de admin.
# Entran el repartidor y el admin (vista previa). Ver docs/REPARTOS_Y_RENDICIONES.md.
class Reparto::BaseController < ApplicationController
  layout "reparto"

  before_action :authenticate_user!
  before_action :require_driver_or_admin!

  rescue_from ActiveRecord::RecordNotFound do
    redirect_to reparto_root_path, alert: "Eso ya no está en tus repartos."
  end

  private

  # Registrar entregas es solo del repartidor; el admin mira desde Repartos → "Ver como repartidor".
  def require_driver!
    return if current_user.driver?

    redirect_to admin_delivery_routes_path, notice: "Para ver el recorrido de un repartidor usá \"Ver como repartidor\" en Repartos."
  end

  # Recorridos de HOY del repartidor (puede tener varios: Reparto 1, 2...), por orden de creación.
  def todays_routes
    @todays_routes ||= current_user.delivery_routes.where(date: Date.current).includes(:driver).order(:id).to_a
  end

  # R4: recorridos de DÍAS ANTERIORES del repartidor cuya rendición todavía no envió. Puede
  # completar cobros, gastos y fotos y enviar la rendición; NO registrar entregas atrasadas
  # (las paradas pendientes las revisa administración). Las operaciones quedan con su fecha y
  # hora reales; el recorrido conserva su fecha original.
  def pending_past_routes
    @pending_past_routes ||= current_user.delivery_routes.where("date < ?", Date.current).where(status: %w[draft in_progress])
                                         .includes(:driver).order(:date, :id).to_a
  end

  # Todo lo que el repartidor puede abrir: sus recorridos de hoy y los anteriores sin rendir.
  def driver_routes
    todays_routes + pending_past_routes
  end

  def past_route?(route)
    route.date < Date.current
  end

  # "Inicio" de un recorrido: con un solo reparto hoy es la portada; si no, la pantalla de ese reparto.
  def route_home_path(route)
    past_route?(route) || todays_routes.many? ? reparto_route_path(route) : reparto_root_path
  end
  helper_method :route_home_path, :todays_routes, :pending_past_routes, :past_route?

  # Una parada de los recorridos del repartidor (hoy o anteriores sin rendir); nunca de otro repartidor.
  def find_driver_stop(id)
    DeliveryStop.visible.where(delivery_route_id: driver_routes.map(&:id)).includes(order: [:customer, :order_items]).find(id)
  end

  def find_driver_route(id)
    driver_routes.find { |route| route.id == id.to_i } || raise(ActiveRecord::RecordNotFound)
  end

  # Importe escrito en pesos ("13500", "13.500", "$ 13.500") → centavos, o nil.
  def parse_pesos(text)
    CustomerAccounts::Money.parse_pesos(text)
  end
end
