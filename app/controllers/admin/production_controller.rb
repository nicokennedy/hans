class Admin::ProductionController < ApplicationController
  before_action :authenticate_user!, except: [:public_print]
  before_action :require_admin_or_production!, except: [:public_print]

  def index
    today = Date.current

    @week_days = (today..6.days.from_now.to_date).map { |date| ProductionDaySheet.day_summary(date) }

    past_dates = ProductionDaySheet.dates_with_orders(from: 30.days.ago.to_date, to: today - 1.day)
    @past_days = past_dates.map { |date| ProductionDaySheet.day_summary(date) }
  end

  def show
    @selected_date = Date.parse(params[:id])

    sheet = ProductionDaySheet.for(@selected_date)
    @customers = sheet.customers
    @rows = sheet.rows
    @special_items = sheet.special_items
  end

  def print
    show
    render :print, layout: false
  end

  def public_print
    show
    render :print, layout: false
  end

end