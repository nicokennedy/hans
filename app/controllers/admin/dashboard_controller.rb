class Admin::DashboardController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin!

  def show
  end

  private

  def require_admin!
    redirect_to dashboard_path, alert: "No tenés permisos para acceder." unless current_user.admin?
  end
end