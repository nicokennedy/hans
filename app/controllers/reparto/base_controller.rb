# Portal del repartidor (/reparto). Pensado para el iPhone corporativo y para una persona con
# poca experiencia con sistemas: layout propio, sin menú lateral ni pantallas de admin.
# Entran el repartidor y el admin (vista previa). Ver docs/REPARTOS_Y_RENDICIONES.md.
class Reparto::BaseController < ApplicationController
  layout "reparto"

  before_action :authenticate_user!
  before_action :require_driver_or_admin!

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

  # "Inicio" de un recorrido: con un solo reparto es la portada; con varios, la pantalla de ese reparto.
  def route_home_path(route)
    todays_routes.many? ? reparto_route_path(route) : reparto_root_path
  end
  helper_method :route_home_path, :todays_routes
end
