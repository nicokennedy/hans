# Consolida la demanda de UNA fecha de entrega para la planilla de producción: pedidos
# mayoristas + pedidos minoristas (no cancelados) en una sola planilla, sin crear pedidos
# artificiales. Los productos de catálogo se suman por id REAL de producto (20 + 15 + 12 =
# 47) y los minoristas se muestran en la columna "HANS" (es solo una etiqueta: no es el
# cliente mayorista). Los productos manuales no tienen producto: van aparte, al final, como
# "PRODUCTOS ESPECIALES — HANS", con comprador, horario y observaciones.
class ProductionDaySheet
  RETAIL_COLUMN = "HANS".freeze

  SpecialItem = Struct.new(:description, :quantity, :buyer_name, :time_note, :delivery_kind_label, :notes, :retail_order, keyword_init: true)

  attr_reader :date, :customers, :rows, :special_items

  def self.for(date)
    new(date)
  end

  # Totales del día para el índice de producción (mayoristas + minoristas).
  def self.day_summary(date)
    wholesale = Order.includes(:order_items).where(delivery_date: date).where.not(status: "canceled")
    retail = RetailOrder.includes(:retail_order_items).for_delivery_date(date)

    {
      date: date,
      orders_count: wholesale.size + retail.size,
      items_count: wholesale.sum { |order| order.order_items.sum(&:quantity) } + retail.sum { |order| order.retail_order_items.sum(&:quantity) },
      customers_count: wholesale.map(&:customer_id).uniq.size + (retail.any? ? 1 : 0)
    }
  end

  def self.dates_with_orders(from:, to:)
    wholesale = Order.where.not(status: "canceled").where(delivery_date: from..to).distinct.pluck(:delivery_date)
    retail = RetailOrder.not_canceled.where(delivery_date: from..to).distinct.pluck(:delivery_date)
    (wholesale | retail).sort.reverse
  end

  def initialize(date)
    @date = date
    build
  end

  def empty?
    rows.empty? && special_items.empty?
  end

  private

  def build
    orders = Order.includes(:customer, :order_items).where(delivery_date: date).where.not(status: "canceled")
    retail_orders = RetailOrder.for_delivery_date(date).includes(retail_order_items: :product).order(:delivery_time_note, :id)

    names = orders.map { |order| order.customer.name }
    names << RETAIL_COLUMN if retail_orders.any?
    @customers = names.uniq.sort_by(&:to_s)

    grouped = Hash.new { |hash, key| hash[key] = Hash.new(0) }
    display_names = {}
    product_ids = []

    orders.each do |order|
      order.order_items.each do |item|
        grouped[item.product_id][order.customer.name] += item.quantity
        display_names[item.product_id] ||= item.product_name_snapshot
        product_ids << item.product_id
      end
    end

    @special_items = []
    retail_orders.each do |retail|
      retail.retail_order_items.each do |item|
        if item.catalog?
          grouped[item.product_id][RETAIL_COLUMN] += item.quantity
          display_names[item.product_id] ||= item.product&.name || item.product_name_snapshot
          product_ids << item.product_id
        else
          @special_items << SpecialItem.new(
            description: item.description, quantity: item.quantity, buyer_name: retail.buyer_name,
            time_note: retail.delivery_time_note, delivery_kind_label: retail.delivery_kind_label, notes: retail.notes, retail_order: retail
          )
        end
      end
    end

    categories = Product.where(id: product_ids.uniq).pluck(:id, :internal_category).to_h

    @rows = grouped.map do |product_id, quantities_by_customer|
      {
        product_id: product_id,
        product_name: display_names[product_id],
        total: quantities_by_customer.values.sum,
        quantities_by_customer: quantities_by_customer,
        internal_category: categories[product_id]
      }
    end.sort_by { |row| [ row[:internal_category].to_s.downcase, row[:product_name].to_s.downcase ] }
  end
end
