# Repartos (R2/R3): administración arma y edita los recorridos diarios con pedidos mayoristas
# reales. Una fecha puede tener varios recorridos, también varios del mismo repartidor
# (Reparto 1, 2...). Solo admin. No modifica pedidos, pagos, stock ni cuentas corrientes (ver
# DeliveryRoutes::Create / Editor). La demostración R1 sigue aparte, en /admin/repartos/demo.
class Admin::DeliveryRoutesController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin!
  before_action :set_route, only: [:show, :driver, :sheet, :preview]

  # Una fecha puede tener varios recorridos, de distintos repartidores o del mismo.
  def index
    @date = parse_date(params[:date]) || Date.current
    @routes = DeliveryRoute.where(date: @date).includes(:driver).order(:id).to_a
    @unassigned = DeliveryRoute.unassigned_orders_for(@date).to_a
    @available_drivers = User.active_drivers.to_a
    # Un token por formulario: si "Crear reparto" llega dos veces, se crea un solo recorrido.
    @creation_token = SecureRandom.uuid
    @stop_counts = DeliveryStop.active.where(delivery_route_id: @routes.map(&:id)).group(:delivery_route_id, :delivery_status).count
    @recent_routes = DeliveryRoute.recent_first.includes(:driver).limit(12)
    @stops_count = DeliveryStop.active.group(:delivery_route_id).count
  end

  def create
    date = parse_date(params[:date])
    driver = User.find_by(id: params[:driver_id])
    result = DeliveryRoutes::Create.call(date: date, order_ids: params[:order_ids], user: current_user, driver: driver,
                                         creation_token: params[:creation_token])
    if result.ok? && result.already
      redirect_to admin_delivery_route_path(result.route), notice: "Ese reparto ya estaba creado: no se duplicó."
    elsif result.ok?
      redirect_to admin_delivery_route_path(result.route), notice: "Listo: #{result.route.title} del #{l(date, format: '%d/%m/%Y')} guardado con #{result.route.active_stops.count} parada(s)."
    else
      redirect_to admin_delivery_routes_path(date: date&.iso8601), alert: result.errors.join(" ")
    end
  end

  def show
    load_route_details
    @drivers = User.active_drivers.to_a
    @siblings = @route.siblings.to_a
  end

  def driver
    driver = User.find_by(id: params[:driver_id])
    result = DeliveryRoutes::Editor.new(@route, current_user).assign_driver(driver)
    redirect_to admin_delivery_route_path(@route), result.ok? ? { notice: "Repartidor actualizado." } : { alert: result.errors.join(" ") }
  end

  # Hoja de ruta para imprimir: guía en papel, no reemplaza el registro digital.
  def sheet
    load_route_details
    render layout: false
  end

  # Cómo va a ver el recorrido el repartidor en el celular (solo lectura, sin acciones).
  def preview
    @stops = @route.active_stops.includes(:delivery_recorded_by, order: [:customer, :order_items]).to_a
    @stop = @stops.find { |s| s.id == params[:stop_id].to_i } if params[:stop_id]
    render layout: "reparto"
  end

  private

  def set_route
    @route = DeliveryRoute.find(params[:id])
  end

  def load_route_details
    @stops = @route.active_stops.includes(:delivery_recorded_by, order: :customer).to_a
    @removed = @route.removed_stops.includes(:removed_by, order: :customer).to_a
    @unassigned = @route.unassigned_orders.to_a
    @events = @route.events.includes(:user).reverse
  end

  def parse_date(value)
    Date.iso8601(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
