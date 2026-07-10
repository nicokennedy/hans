class ApplicationController < ActionController::Base
  before_action :ensure_active_customer!

  def after_sign_in_path_for(resource)
    if resource.admin?
      admin_root_path
    else
      dashboard_path
    end
  end

  private

  def ensure_active_customer!
    return unless user_signed_in?
    return if current_user.admin?

    if current_user.customer.blank?
      sign_out(current_user)
      redirect_to new_user_session_path, alert: "Tu cuenta no está asociada a un cliente. Contactá a HANS."
    elsif !current_user.customer.active?
      sign_out(current_user)
      redirect_to new_user_session_path, alert: "Tu acceso se encuentra desactivado. Contactá a HANS."
    end
  end
end
