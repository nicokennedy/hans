# app/models/product.rb
class Product < ApplicationRecord
  belongs_to :category
  has_many :order_items, dependent: :restrict_with_error

  validates :name, :price_cents, presence: true
  validates :price_cents, :cost_cents, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  scope :active, -> { where(active: true) }
  scope :ordered, -> { joins(:category).order("categories.position ASC, products.position ASC, products.name ASC") }

  def price
    price_cents.to_i / 100.0
  end
end