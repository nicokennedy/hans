class DashboardsController < ApplicationController
  before_action :authenticate_user!

  def show
    if current_user.admin?
      redirect_to admin_root_path
    elsif current_user.production?
      redirect_to admin_production_index_path
    end
  end
end