# Administración → Usuarios (R3): usuarios internos de HANS. Solo admin. Las reglas (roles
# válidos, último administrador, propio acceso, repartidores con recorridos) viven en
# Users::Manage. Las contraseñas temporales se muestran una sola vez y nunca se guardan legibles.
class Admin::UsersController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin!
  before_action :set_user, only: [:show, :edit, :update, :activate, :deactivate, :reset_password]

  ROLE_FILTERS = %w[all admin production driver].freeze
  STATUS_FILTERS = %w[all active inactive].freeze

  def index
    @role = ROLE_FILTERS.include?(params[:role]) ? params[:role] : "all"
    @status = STATUS_FILTERS.include?(params[:status]) ? params[:status] : "all"
    scope = User.internal
    scope = scope.where(role: @role) unless @role == "all"
    scope = scope.where(active: @status == "active") unless @status == "all"
    @users = scope.to_a.sort_by { |u| [u.active? ? 0 : 1, u.display_name.downcase] }
    @pending_routes = DeliveryRoute.where(driver_id: @users.map(&:id)).where("date >= ?", Date.current).group(:driver_id).count
  end

  def show
    @events = @user.user_events.includes(:actor).reverse
    @routes = @user.delivery_routes.where("date >= ?", Date.current - 30).order(date: :desc).limit(30) if @user.driver?
  end

  def new
    @user = User.new(role: params[:role].presence_in(User::INTERNAL_ROLES) || "driver")
  end

  def create
    result = manager.create(**user_params)
    @user = result.user
    if result.ok?
      show_temporary_password(result.password, "Usuario creado")
    else
      flash.now[:alert] = result.errors.join(" ")
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    result = manager.update(@user, **user_params)
    if result.ok?
      redirect_to admin_user_path(@user), notice: "Datos guardados."
    else
      @user.restore_attributes
      flash.now[:alert] = result.errors.join(" ")
      render :edit, status: :unprocessable_entity
    end
  end

  def activate
    respond_with_status manager.set_active(@user, true), "Acceso activado."
  end

  def deactivate
    respond_with_status manager.set_active(@user, false), "Acceso desactivado: #{@user.display_name} ya no puede ingresar y sus sesiones abiertas se cierran."
  end

  def reset_password
    result = manager.reset_password(@user)
    if result.ok?
      show_temporary_password(result.password, "Contraseña restablecida")
    else
      redirect_to admin_user_path(@user), alert: result.errors.join(" ")
    end
  end

  private

  def manager
    Users::Manage.new(current_user)
  end

  def set_user
    @user = User.internal.find(params[:id])
  end

  def user_params
    permitted = params.require(:user).permit(:name, :email, :role)
    # El rol propio se muestra deshabilitado (no viaja en el formulario): se conserva el actual.
    { name: permitted[:name], email: permitted[:email], role: permitted[:role].presence || @user&.role }
  end

  # La contraseña temporal se muestra en ESTA respuesta y en ninguna otra: no se redirige (no
  # pasa por la sesión ni el flash) y la página no se guarda en el caché del navegador.
  def show_temporary_password(password, title)
    response.headers["Cache-Control"] = "no-store"
    @temporary_password = password
    @title = title
    render :temporary_password
  end

  def respond_with_status(result, notice)
    if result.ok?
      redirect_to admin_user_path(@user), notice: [notice, *result.warnings].join(" ")
    else
      redirect_to admin_user_path(@user), alert: result.errors.join(" ")
    end
  end
end
