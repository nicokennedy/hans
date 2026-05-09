# app/models/category.rb
class Category < ApplicationRecord
  has_many :products, dependent: :restrict_with_error

  validates :name, presence: true

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:position, :name) }
end