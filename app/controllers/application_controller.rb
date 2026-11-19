class ApplicationController < ActionController::Base
  before_action :ensure_active_customer!
  # Administración → Usuarios: quien entra con una contraseña temporal tiene que cambiarla antes
  # de usar HANS (ver PasswordChangesController).
  before_action :require_password_change!, unless: :devise_controller?

  def after_sign_in_path_for(resource)
    if resource.admin?
      admin_root_path
    elsif resource.production?
      admin_production_index_path
    elsif resource.driver?
      reparto_root_path
    else
      dashboard_path
    end
  end

  private

  def ensure_active_customer!
    return unless user_signed_in?
    return if current_user.admin_or_production? || current_user.driver?

    if current_user.customer.blank?
      sign_out(current_user)
      redirect_to new_user_session_path, alert: "Tu cuenta no está asociada a un cliente. Contactá a HANS."
    elsif !current_user.customer.active?
      sign_out(current_user)
      redirect_to new_user_session_path, alert: "Tu acceso se encuentra desactivado. Contactá a HANS."
    end
  end

  def require_password_change!
    return unless user_signed_in? && current_user.must_change_password?

    redirect_to edit_password_change_path
  end

  # Bloquea rutas exclusivas de admin. Centralizado acá porque estaba
  # duplicado idéntico en 6 controladores admin distintos.
  def require_admin!
    return if current_user&.admin?

    redirect_to admin_unauthorized_fallback_path, alert: "No tenés permisos para acceder."
  end

  # Igual que require_admin!, pero también deja pasar al perfil production
  # (solo lectura: pedidos y producción).
  def require_admin_or_production!
    return if current_user&.admin_or_production?

    redirect_to admin_unauthorized_fallback_path, alert: "No tenés permisos para acceder."
  end

  def admin_unauthorized_fallback_path
    if current_user&.production?
      admin_production_index_path
    elsif current_user&.driver?
      reparto_root_path
    else
      dashboard_path
    end
  end

  # Portal del repartidor (/reparto). Admin también entra, como vista previa.
  def require_driver_or_admin!
    return if current_user&.driver? || current_user&.admin?

    redirect_to admin_unauthorized_fallback_path, alert: "No tenés permisos para acceder."
  end

  # Bloquea rutas exclusivas de clientes (carrito, pedidos propios, portal).
  # Centralizado porque estaba duplicado en CartsController y OrdersController.
  def require_customer!
    if current_user.admin?
      redirect_to admin_root_path
    elsif current_user.production?
      redirect_to admin_production_index_path
    elsif current_user.driver?
      redirect_to reparto_root_path
    end
  end
end
