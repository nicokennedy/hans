# app/models/order_item.rb
class OrderItem < ApplicationRecord
  belongs_to :order
  belongs_to :product

  validates :quantity, numericality: { greater_than: 0 }

  before_validation :set_snapshots, on: :create
  before_validation :calculate_totals

  private

  def set_snapshots
    self.product_name_snapshot ||= product.name
    self.category_name_snapshot ||= product.category&.name
    self.unit_price_cents_snapshot ||= product.price_cents
    self.unit_cost_cents_snapshot ||= product.cost_cents.to_i
  end

  def calculate_totals
    self.line_revenue_cents = quantity.to_i * unit_price_cents_snapshot.to_i
    self.line_cost_cents = quantity.to_i * unit_cost_cents_snapshot.to_i
  end
end