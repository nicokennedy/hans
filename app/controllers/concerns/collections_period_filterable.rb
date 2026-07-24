module CollectionsPeriodFilterable
  extend ActiveSupport::Concern

  included do
    before_action :set_collections_period
  end

  private

  def set_collections_period
    if params[:period].present?
      session[:collections_period] = {
        "period" => params[:period],
        "from" => params[:from],
        "to" => params[:to]
      }
    end

    stored = session[:collections_period] || {}
    @collections_period = Collections::PeriodFilter.new(
      period: stored["period"],
      from: stored["from"],
      to: stored["to"]
    )
  end
end
