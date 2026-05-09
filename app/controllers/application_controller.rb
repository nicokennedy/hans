class ApplicationController < ActionController::Base
  def after_sign_in_path_for(resource)
    if resource.admin?
      admin_root_path
    else
      dashboard_path
    end
  end
end