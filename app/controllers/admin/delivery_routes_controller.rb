# Repartos (R2): administración arma y edita los recorridos diarios con pedidos mayoristas
# reales. Solo admin. No modifica pedidos, pagos, stock ni cuentas corrientes (ver
# DeliveryRoutes::Create / Editor). La demostración R1 sigue aparte, en /admin/repartos/demo.
class Admin::DeliveryRoutesController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin!
  before_action :set_route, only: [:show, :driver, :sheet, :preview]

  def index
    @date = parse_date(params[:date]) || Date.current
    @route = DeliveryRoute.find_by(date: @date, driver_id: nil) || DeliveryRoute.where(date: @date).order(:id).first
    @orders = @route ? Order.none : available_orders(@date)
    @recent_routes = DeliveryRoute.recent_first.includes(:driver).limit(10)
    @stops_count = DeliveryStop.active.group(:delivery_route_id).count
  end

  def create
    date = parse_date(params[:date])
    result = DeliveryRoutes::Create.call(date: date, order_ids: params[:order_ids], user: current_user)
    if result.ok?
      redirect_to admin_delivery_route_path(result.route), notice: "Listo: recorrido del #{l(date, format: '%d/%m/%Y')} guardado con #{result.route.active_stops.count} parada(s)."
    elsif result.route
      redirect_to admin_delivery_route_path(result.route), alert: result.errors.join(" ")
    else
      redirect_to admin_delivery_routes_path(date: date&.iso8601), alert: result.errors.join(" ")
    end
  end

  def show
    load_route_details
    @drivers = User.where(role: "driver").order(:email)
  end

  def driver
    driver = params[:driver_id].present? ? User.find_by(id: params[:driver_id]) : nil
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
    @stops = @route.active_stops.includes(order: [:customer, :order_items]).to_a
    @stop = @stops.find { |s| s.id == params[:stop_id].to_i } if params[:stop_id]
    render layout: "reparto"
  end

  private

  def set_route
    @route = DeliveryRoute.find(params[:id])
  end

  def load_route_details
    @stops = @route.active_stops.includes(order: :customer).to_a
    @removed = @route.removed_stops.includes(:removed_by, order: :customer).to_a
    @unassigned = @route.unassigned_orders.to_a
    @events = @route.events.includes(:user).reverse
  end

  def available_orders(date)
    taken = DeliveryStop.active.where.not(order_id: nil).select(:order_id)
    Order.for_delivery_date(date).where.not(id: taken).includes(:customer).joins(:customer).order(Arel.sql("lower(customers.name)"), :id)
  end

  def parse_date(value)
    Date.iso8601(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
