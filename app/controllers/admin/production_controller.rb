class Admin::ProductionController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin!

  def index
    today = Date.current

    @week_days = (today..6.days.from_now.to_date).map do |date|
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

    past_dates = Order
      .where.not(status: "canceled")
      .where("delivery_date < ?", today)
      .where("delivery_date >= ?", 30.days.ago.to_date)
      .distinct
      .order(delivery_date: :desc)
      .pluck(:delivery_date)

    @past_days = past_dates.map do |date|
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
  end

  def show
    @selected_date = Date.parse(params[:id])

    orders = Order
      .includes(:customer, :order_items)
      .where(delivery_date: @selected_date)
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