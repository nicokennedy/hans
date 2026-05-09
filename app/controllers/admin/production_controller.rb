class Admin::ProductionController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin!

  def index
    @delivery_date = params[:date].presence || params[:delivery_date].presence || Date.current.to_s
    selected_date = Date.parse(@delivery_date.to_s)
    @selected_date = selected_date

    @week_days = (Date.current..6.days.from_now.to_date).map do |date|
      orders_for_day = Order
        .includes(:customer, :order_items)
        .where(delivery_date: date)
        .where.not(status: "canceled")

      {
        date: date,
        orders_count: orders_for_day.count,
        items_count: orders_for_day.sum { |order| order.order_items.sum(&:quantity) },
        customers_count: orders_for_day.map(&:customer_id).uniq.count
      }
    end

    orders = Order
      .includes(:customer, :order_items)
      .where(delivery_date: selected_date)
      .where.not(status: "canceled")

    @customers = orders.map(&:customer).uniq.sort_by(&:name)

    grouped = Hash.new { |hash, key| hash[key] = Hash.new(0) }

    orders.each do |order|
      order.order_items.each do |item|
        grouped[item.product_name_snapshot][order.customer.name] += item.quantity
      end
    end

    @rows = grouped.map do |product_name, quantities_by_customer|
      {
        product_name: product_name,
        total: quantities_by_customer.values.sum,
        quantities_by_customer: quantities_by_customer
      }
    end.sort_by { |row| row[:product_name] }
  end

  private

  def require_admin!
    redirect_to dashboard_path, alert: "No tenés permisos para acceder." unless current_user.admin?
  end
end