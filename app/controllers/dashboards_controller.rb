class DashboardsController < ApplicationController
  before_action :authenticate_user!

  def show
    redirect_to admin_root_path if current_user.admin?
  end
end