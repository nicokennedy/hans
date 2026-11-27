class Admin::DeliveryIncomesController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin!
  include DeliveryIncomeForms

  private

  def load_income_route
    @route = DeliveryRoute.find(params[:delivery_route_id])
  end

  def income_index_path
    admin_delivery_route_incomes_path(@route)
  end
end
