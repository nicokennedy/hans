class Admin::DashboardController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin!

  def show
    @stock_needing_production_count = Stock::Availability.dashboard.count { |snapshot| snapshot.production_needed.positive? }
  end
end