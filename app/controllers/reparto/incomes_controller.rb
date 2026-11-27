class Reparto::IncomesController < Reparto::BaseController
  before_action :require_driver!
  include DeliveryIncomeForms

  private

  def load_income_route
    @route = find_driver_route(params[:route_id])
  end

  def income_index_path
    reparto_route_incomes_path(@route)
  end
end
