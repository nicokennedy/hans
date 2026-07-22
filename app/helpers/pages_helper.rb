module PagesHelper
  def home_cta_text
    if !user_signed_in?
      "Ingresar a la tienda"
    elsif current_user.admin?
      "Ir al panel"
    else
      "Ir a mi portal"
    end
  end

  def home_cta_path
    if !user_signed_in?
      new_user_session_path
    elsif current_user.admin?
      admin_root_path
    else
      dashboard_path
    end
  end
end
