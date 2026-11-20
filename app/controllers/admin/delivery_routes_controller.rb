# Repartos (R2/R3): administración arma y edita los recorridos diarios con pedidos mayoristas
# reales. Una fecha puede tener varios recorridos, también varios del mismo repartidor
# (Reparto 1, 2...). Solo admin. No modifica pedidos, pagos, stock ni cuentas corrientes (ver
# DeliveryRoutes::Create / Editor). La demostración R1 sigue aparte, en /admin/repartos/demo.
class Admin::DeliveryRoutesController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin!
  before_action :set_route, only: [:show, :driver, :sheet, :preview, :confirm_settlement]

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
    # D8: recorridos de días anteriores que todavía no enviaron la rendición.
    @overdue_routes = DeliveryRoute.where("date < ?", Date.current).where(status: %w[draft in_progress]).where.not(driver_id: nil).includes(:driver).order(:date, :id).to_a
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
    @settlement = DeliveryRoutes::Settlement.new(@route)
    @expense_categories = ExpenseCategory.active.ordered.to_a
    @default_category = DeliveryRoutes::Settlements.default_category
  end

  # R4: confirmar el cierre de la rendición (solo admin, sin reabrir).
  def confirm_settlement
    categories = params[:categorias].is_a?(ActionController::Parameters) ? params[:categorias].to_unsafe_h.transform_keys(&:to_i).transform_values(&:to_i) : {}
    result = DeliveryRoutes::Settlements.new(@route, current_user).confirm(
      counted_cents: CustomerAccounts::Money.parse_pesos(params[:contado]), note: params[:nota], categories: categories
    )
    if result.ok?
      redirect_to admin_delivery_route_path(@route, anchor: "rendicion"), notice: result.already ? "El cierre ya estaba confirmado." : "Cierre confirmado."
    else
      redirect_to admin_delivery_route_path(@route, anchor: "rendicion"), alert: result.errors.join(" ")
    end
  end

  # R4: historial de rendiciones (por confirmar, confirmadas, con diferencia de caja).
  FILTERS = { "pendientes" => "Por confirmar", "sin_enviar" => "Sin enviar (días anteriores)", "confirmadas" => "Confirmadas",
              "diferencias" => "Con diferencia o pendiente", "todas" => "Todas" }.freeze
  def settlements
    @filter = FILTERS.key?(params[:filtro]) ? params[:filtro] : "pendientes"
    @from = parse_date(params[:desde])
    @to = parse_date(params[:hasta])
    @driver_id = params[:repartidor].presence&.to_i
    @drivers = User.where(role: "driver").order(Arel.sql("lower(coalesce(users.name, users.email))")).to_a
    scope = DeliveryRoute.includes(:driver, :confirmed_by).order(date: :desc, id: :desc)
    scope = case @filter
            when "pendientes" then scope.where(status: "submitted")
            when "sin_enviar" then scope.where("date < ?", Date.current).where(status: %w[draft in_progress]).where.not(driver_id: nil)
            when "confirmadas" then scope.where(status: "confirmed")
            when "diferencias" then scope.where(status: "confirmed").where("difference_cents <> 0 OR unresolved_cents > 0")
            else scope.where(status: %w[submitted confirmed]).or(scope.where("date < ?", Date.current).where(status: %w[draft in_progress]).where.not(driver_id: nil))
            end
    scope = scope.where("date >= ?", @from) if @from
    scope = scope.where("date <= ?", @to) if @to
    scope = scope.where(driver_id: @driver_id) if @driver_id
    @routes = scope.limit(200).to_a
    # Para las rendiciones sin enviar todavía no hay totales congelados: se calculan en vivo.
    @live = @routes.reject { |r| r.submitted? || r.confirmed? }.to_h { |r| [r.id, DeliveryRoutes::Settlement.new(r)] }
    @voided_after_close = DeliveryCollection.joins(:customer_payment).where(delivery_route_id: @routes.map(&:id), voided_at: nil)
                                            .where.not(customer_payments: { voided_at: nil }).group(:delivery_route_id).count
    @overdue_routes = DeliveryRoute.where("date < ?", Date.current).where(status: %w[draft in_progress]).where.not(driver_id: nil).includes(:driver).order(:date, :id).to_a
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
